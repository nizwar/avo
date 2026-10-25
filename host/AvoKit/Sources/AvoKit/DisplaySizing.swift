import CoreGraphics
import Foundation

// The sizing rules app windows share: which size and density Android's
// display gets for a window, when a change is worth re-plugging the display
// (the app's tasks move to display 0 and back), where the picture goes in the
// window, and how the renderer scales it. The Window Host, its renderer, the
// touch mapping and the Control Panel's preview all call these, so the
// picture, the touches and the preview always agree.

/// A size in pixels.
public struct PixelSize: Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// A rectangle in pixels, origin at the top left.
public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var size: PixelSize { PixelSize(width: width, height: height) }
}

/// The size and density a window asks Android's display to have.
public struct DisplayRequest: Equatable, Sendable {
    public var width: UInt32
    public var height: UInt32
    public var dpi: UInt32
    /// Follow mode: the render scale in effect after the floors, in percent
    /// (rounded up); nil in fixed mode and for the phone's screen.
    public var effectiveRenderScale: Int?
    /// The 120-dpi floor raised the render scale, or the density hit the
    /// 120…640 clamp (Android's lowest and highest densities).
    public var limitedByDensity: Bool
    /// The 240-px minimum raised the render scale, or the 8192-px maximum
    /// shrank the display.
    public var limitedBySize: Bool

    public init(width: UInt32, height: UInt32, dpi: UInt32, effectiveRenderScale: Int? = nil,
                limitedByDensity: Bool = false, limitedBySize: Bool = false) {
        self.width = width
        self.height = height
        self.dpi = dpi
        self.effectiveRenderScale = effectiveRenderScale
        self.limitedByDensity = limitedByDensity
        self.limitedBySize = limitedBySize
    }

    public var size: PixelSize { PixelSize(width: Int(width), height: Int(height)) }

    /// The screen Android lays out for, in dp.
    public var layoutDP: PixelSize {
        guard dpi > 0 else { return size }
        return PixelSize(width: Int((Double(width) * 160 / Double(dpi)).rounded()),
                         height: Int((Double(height) * 160 / Double(dpi)).rounded()))
    }
}

/// How the renderer turns Android's frame into the picture on screen.
public enum ScalingPath: Equatable, Sendable {
    /// Same size: a 1:1 copy (edge pixels repeat into a gap of a few pixels).
    case native
    /// MetalFX enlarges to `output`; when that is smaller than the
    /// destination (the ×4 cap), a bilinear pass does the rest.
    case metalFX(output: PixelSize)
    case bilinear
    case nearest
    /// Shrinking: `taps` × `taps` bilinear samples per destination pixel.
    case downsample(taps: Int)
}

public enum DisplaySizing {
    /// The smallest side Avo gives Android, in pixels (windows are at least
    /// 240 points).
    public static let minimumSide = 240
    /// The largest display side Avo asks for.
    public static let maximumSide = 8192
    /// Widths are multiples of 8 because virtio-gpu display modes are 8-pixel
    /// aligned: any other width gave Android a narrower mode than the window
    /// measured touches in, so touches and the picture disagreed.
    public static let widthAlignment = 8
    /// The short side of a typical phone in dp, the layout fixed mode aims at.
    public static let referenceShortSideDP = 412
    /// Android's lowest and highest densities (ldpi and xxxhdpi). Fixed
    /// resolutions above 1600 px reach the highest at the default interface
    /// size, so Android lays them out a little larger than 412 dp (540 dp
    /// at 4K), still well short of a tablet's 600.
    public static let minimumDPI = 120
    public static let maximumDPI = 640
    /// The highest density supersampling takes Android to (its own top is
    /// 640): the layout stays the same as without it up to here.
    public static let maximumSupersampledDPI = 1280
    /// Fixed + Match window re-plugs once the window's shape is more than 1%
    /// off what Android has.
    public static let replugTolerance = 0.01
    /// A shape mismatch up to 2% is stretched to fill (invisible); a larger
    /// one is fitted with black bars. It covers both `replugTolerance` and the
    /// rounding of a fresh request (≤ 4/long + 1/short, 1.4% at 360 px).
    public static let fillTolerance = 0.02
    /// Below this enlargement MetalFX costs more than it shows.
    public static let minimumMetalFXRatio = 1.05
    /// The largest enlargement Avo asks of MetalFX, which bounds the
    /// scaler's output memory; bilinear does the rest.
    public static let maximumMetalFXRatio = 4.0

    // MARK: Requests

    /// What a window with this content size (points) asks for. `landscape`
    /// is the orientation of a locked shape (default: the window's; a square
    /// counts as portrait), `device` the device profile's screen.
    ///
    /// Follow mode: the window's pixels × the render scale, raised so the
    /// density stays at least 120 dpi and the short side at least 240 px; the
    /// density is 160 dpi per point × the interface size × the scale, so the
    /// layout is the same at every render scale. A fixed ratio takes the
    /// largest part of the content in that shape (all of a window locked to
    /// it; full screen keeps bars). Fixed mode: `shortSide` × the aspect
    /// ratio (the window's, for Match window), with a density that keeps the
    /// short side about 412 dp. The phone's screen: the phone's pixels at its
    /// density. Neither of the last two depends on `backingScale`.
    public static func request(contentWidth: Double, contentHeight: Double, backingScale: Double,
                               settings: GraphicsSettings, device: DeviceProfile.Display? = nil, landscape: Bool? = nil) -> DisplayRequest {
        let width = contentWidth.isFinite ? max(contentWidth, 0) : 0
        let height = contentHeight.isFinite ? max(contentHeight, 0) : 0
        let mode = settings.effectiveMode(device: device)
        let factor = settings.antiAliasing.supersampling
        if mode == .deviceProfile, let device {
            return supersampled(deviceRequest(device, landscape: landscape ?? (width > height)), by: factor)
        }
        if mode == .fixed {
            return supersampled(fixedRequest(width: width, height: height, settings: settings, landscape: landscape), by: factor)
        }
        let scale = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        var content = (width: width, height: height)
        if let ratio = settings.followAspectRatio.longOverShort {
            content = fittedContentSize(width: width, height: height, longOverShort: ratio, landscape: landscape ?? (width > height))
        }
        return supersampled(followRequest(width: content.width, height: content.height, backingScale: scale, settings: settings), by: factor)
    }

    /// `request` × `factor` on each side and on the density, so Android lays
    /// out the same and the renderer shrinks the frame back (supersampling);
    /// less where the largest display or density stops it.
    private static func supersampled(_ request: DisplayRequest, by factor: Double) -> DisplayRequest {
        guard factor > 1, request.width > 0, request.height > 0, request.dpi > 0 else { return request }
        let longest = Double(max(request.width, request.height))
        let k = min(factor, Double(maximumSide) / longest, Double(maximumSupersampledDPI) / Double(request.dpi))
        guard k > 1 else {
            var limited = request
            limited.limitedBySize = true
            return limited
        }
        let w = floor(Double(request.width) * k, to: widthAlignment)
        // The height and density for the width actually reached, so the layout matches.
        let reached = Double(w) / Double(request.width)
        let h = floor(Double(request.height) * reached, to: 2)
        let dpi = Int((Double(request.dpi) * reached).rounded())
        return DisplayRequest(width: UInt32(w), height: UInt32(h), dpi: UInt32(dpi), effectiveRenderScale: request.effectiveRenderScale,
                              limitedByDensity: request.limitedByDensity, limitedBySize: request.limitedBySize || k < factor)
    }

    private static func followRequest(width: Double, height: Double, backingScale b: Double, settings: GraphicsSettings) -> DisplayRequest {
        let base = 160 * b * interfaceFactor(settings.interfaceScale)
        let wanted = Double(clamp(settings.renderScale, GraphicsSettings.renderScaleRange)) / 100
        let densityFloor = Double(minimumDPI) / base
        let shortPixels = min(width, height) * b
        let sizeFloor = shortPixels > 0 ? Double(minimumSide) / shortPixels : 1
        var scale = min(1, max(wanted, densityFloor, sizeFloor))
        let limitedByDensity = densityFloor > wanted && densityFloor >= sizeFloor
        var limitedBySize = sizeFloor > wanted && sizeFloor > densityFloor

        var w: Int
        var h: Int
        if scale >= 1 {
            // Never larger than the window, so the picture stays 1:1.
            w = floor(width * b, to: widthAlignment)
            h = floor(height * b, to: 2)
        } else {
            let pixelsPerPoint = b * scale
            w = nearest(width * pixelsPerPoint, to: widthAlignment)
            h = nearest(height * pixelsPerPoint, to: 2)
        }
        let longest = max(w, h)
        if longest > maximumSide {
            let k = Double(maximumSide) / Double(longest)
            w = floor(Double(w) * k, to: widthAlignment)
            h = floor(Double(h) * k, to: 2)
            scale *= k
            limitedBySize = true
        }
        // Only reachable with a degenerate window; Android needs a real screen.
        w = max(w, minimumSide)
        h = max(h, minimumSide)
        let dpi = clamp(Int((base * scale).rounded()), minimumDPI...maximumDPI)
        return DisplayRequest(width: UInt32(w), height: UInt32(h), dpi: UInt32(dpi),
                              effectiveRenderScale: Int((scale * 100 - 1e-9).rounded(.up)),
                              limitedByDensity: limitedByDensity, limitedBySize: limitedBySize)
    }

    private static func fixedRequest(width: Double, height: Double, settings: GraphicsSettings, landscape: Bool?) -> DisplayRequest {
        let clamped = clamp(settings.shortSide, GraphicsSettings.shortSideRange)
        let short = clamped - clamped % 2
        let isLandscape = landscape ?? (width > height)
        let windowAspect = width > 0 && height > 0 ? max(width, height) / min(width, height) : 1
        let aspect = max(1, settings.aspectRatio.longOverShort ?? windowAspect)

        var w: Int
        var h: Int
        var limitedBySize = false
        if isLandscape {
            w = nearest(Double(short) * aspect, to: widthAlignment)
            h = short
            if w > maximumSide {
                w = maximumSide
                h = floor(Double(maximumSide) / aspect, to: 2)
                limitedBySize = true
            }
        } else {
            w = nearest(Double(short), to: widthAlignment)
            h = nearest(Double(w) * aspect, to: 2)
            if h > maximumSide {
                h = maximumSide
                w = floor(Double(maximumSide) / aspect, to: widthAlignment)
                limitedBySize = true
            }
        }
        let density = densityForShortSide(min(w, h), interfaceScale: settings.interfaceScale)
        return DisplayRequest(width: UInt32(w), height: UInt32(h), dpi: UInt32(density.dpi),
                              limitedByDensity: density.clamped, limitedBySize: limitedBySize)
    }

    /// The phone's screen, turned to `landscape` or portrait, at the phone's
    /// own density (within Android's 120…640). A width that is not a multiple
    /// of 8 loses the rest (1220 becomes 1216), which changes the layout by
    /// at most 2 dp.
    private static func deviceRequest(_ display: DeviceProfile.Display, landscape: Bool) -> DisplayRequest {
        let long = clamp(max(display.width, display.height), minimumSide...maximumSide)
        let short = clamp(min(display.width, display.height), minimumSide...maximumSide)
        let w = floor(Double(landscape ? long : short), to: widthAlignment)
        let h = floor(Double(landscape ? short : long), to: 2)
        let dpi = clamp(display.dpi, minimumDPI...maximumDPI)
        return DisplayRequest(width: UInt32(w), height: UInt32(h), dpi: UInt32(dpi), limitedByDensity: dpi != display.dpi,
                              limitedBySize: long != max(display.width, display.height) || short != min(display.width, display.height))
    }

    /// Fixed mode's density: the short side is about 412 dp × the interface
    /// size, in steps of 10 dpi, up to 640. It stays below 600 dp for every
    /// allowed resolution, so Android never treats the screen as a tablet.
    public static func automaticDPI(shortSide: Int, interfaceScale: Int) -> Int {
        densityForShortSide(shortSide, interfaceScale: interfaceScale).dpi
    }

    private static func densityForShortSide(_ short: Int, interfaceScale: Int) -> (dpi: Int, clamped: Bool) {
        let raw = Double(short) * 160 / Double(referenceShortSideDP) * interfaceFactor(interfaceScale)
        let dpi = Int((raw / 10).rounded()) * 10
        let limited = clamp(dpi, minimumDPI...maximumDPI)
        return (limited, limited != dpi)
    }

    /// The lowest render scale follow mode reaches on a screen, in percent:
    /// 38 on Retina screens and 75 on 1× screens at the default interface size,
    /// because Android's density cannot go below 120 dpi.
    public static func minimumRenderScale(backingScale: Double, interfaceScale: Int) -> Int {
        let b = backingScale.isFinite && backingScale > 0 ? backingScale : 1
        let percent = 100 * Double(minimumDPI) / (160 * b * interfaceFactor(interfaceScale))
        return min(100, Int((percent - 1e-9).rounded(.up)))
    }

    // MARK: Re-plugging

    /// Whether `proposed` is worth re-plugging Android's display for, given
    /// what it has (`current`) and the window's shape (width / height). Follow
    /// mode takes every change. Fixed mode and the phone's screen re-plug for
    /// a new density or short side, and otherwise only when the picture would
    /// be visibly distorted: Match window then takes the window's new shape
    /// once, and a fixed shape re-plugs only when it is rotated (the window
    /// is conformed to it first).
    public static func shouldReplug(current: DisplayRequest?, proposed: DisplayRequest, windowAspect: Double, followsWindow: Bool) -> Bool {
        guard let current else { return true }
        if current.width == proposed.width && current.height == proposed.height && current.dpi == proposed.dpi { return false }
        if followsWindow { return true }
        if current.dpi != proposed.dpi || min(current.width, current.height) != min(proposed.width, proposed.height) { return true }
        guard current.width > 0, current.height > 0, windowAspect.isFinite, windowAspect > 0 else { return true }
        let aspect = Double(current.width) / Double(current.height)
        return abs(aspect / windowAspect - 1) > replugTolerance
    }

    // MARK: Presentation

    /// Where Android's frame (`source`) goes in the drawable (`target`):
    /// 1:1 and centred when the drawable is at most a few pixels larger
    /// (rounding to multiples of 8 and 2; the renderer repeats the edge
    /// pixels into the gap, so there is never a black seam), the whole
    /// drawable when the shapes differ by `fillTolerance` or less, and
    /// aspect-fitted with black bars otherwise.
    public static func presentationRect(source: PixelSize, target: PixelSize) -> PixelRect {
        let full = PixelRect(x: 0, y: 0, width: max(target.width, 0), height: max(target.height, 0))
        let (sw, sh, tw, th) = (source.width, source.height, target.width, target.height)
        guard sw > 0, sh > 0, tw > 0, th > 0 else { return full }
        if sw <= tw, sh <= th, tw - sw <= widthAlignment, th - sh <= 2 {
            return PixelRect(x: (tw - sw) / 2, y: (th - sh) / 2, width: sw, height: sh)
        }
        let sourceAspect = Double(sw) / Double(sh)
        let targetAspect = Double(tw) / Double(th)
        if abs(sourceAspect / targetAspect - 1) <= fillTolerance { return full }
        let scale = min(Double(tw) / Double(sw), Double(th) / Double(sh))
        let w = min(tw, Int((Double(sw) * scale).rounded()))
        let h = min(th, Int((Double(sh) * scale).rounded()))
        return PixelRect(x: (tw - w) / 2, y: (th - h) / 2, width: w, height: h)
    }

    /// Whether a press at `point` moves the window instead of touching
    /// Android: off the picture (`picture`, both in view points) by more
    /// than `slack`, in the bars beside a frame that does not fill the
    /// window, as the empty parts of the Control Panel move theirs. Within
    /// `slack` of the picture a press still touches its edge.
    public static func movesWindow(at point: CGPoint, picture: CGRect, slack: CGFloat = 4) -> Bool {
        !picture.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    /// How to scale `source` to `destination` (the presentation rect's size).
    /// MetalFX only enlarges, and only when it shows: both axes at least
    /// ×1.05, and not while the window is being resized (`interactive`),
    /// since a scaler is built per size. Shrinking always averages.
    public static func scalingPath(source: PixelSize, destination: PixelSize, filter: GraphicsSettings.Filter,
                                   metalFXAvailable: Bool, interactive: Bool) -> ScalingPath {
        if source == destination { return .native }
        guard source.width > 0, source.height > 0, destination.width > 0, destination.height > 0 else { return .bilinear }
        let rx = Double(destination.width) / Double(source.width)
        let ry = Double(destination.height) / Double(source.height)
        if rx <= 1 && ry <= 1 {
            let taps = Int((max(1 / rx, 1 / ry) - 1e-9).rounded(.up))
            return .downsample(taps: clamp(taps, 2...4))
        }
        guard rx >= 1 && ry >= 1 else { return .bilinear }
        switch filter {
        case .nearest:
            return .nearest
        case .metalFXSpatial where metalFXAvailable && !interactive && min(rx, ry) >= minimumMetalFXRatio:
            let largest = max(rx, ry)
            guard largest > maximumMetalFXRatio else { return .metalFX(output: destination) }
            let k = maximumMetalFXRatio / largest
            let cap = Int(maximumMetalFXRatio)
            return .metalFX(output: PixelSize(width: min(Int((Double(destination.width) * k).rounded()), source.width * cap),
                                              height: min(Int((Double(destination.height) * k).rounded()), source.height * cap)))
        case .metalFXSpatial, .bilinear:
            return .bilinear
        }
    }

    /// The window content size for a fixed ratio: keeps the long side and
    /// sets the short side (a square counts as portrait, as in `request`).
    public static func conformedContentSize(width: Double, height: Double, longOverShort: Double) -> (width: Double, height: Double) {
        let ratio = longOverShort.isFinite ? max(longOverShort, 1) : 1
        return width > height ? (width, width / ratio) : (height / ratio, height)
    }

    /// The largest content of a fixed ratio inside `width` × `height`, in
    /// `landscape` or portrait. Content already within 1% of that shape (a
    /// window locked to it, up to rounding) is kept whole, so follow mode
    /// stays 1:1 there.
    public static func fittedContentSize(width: Double, height: Double, longOverShort: Double,
                                         landscape: Bool) -> (width: Double, height: Double) {
        guard width > 0, height > 0 else { return (width, height) }
        let ratio = longOverShort.isFinite ? max(longOverShort, 1) : 1
        let aspect = landscape ? ratio : 1 / ratio
        let current = width / height
        if abs(current / aspect - 1) <= replugTolerance { return (width, height) }
        return current > aspect ? (height * aspect, height) : (width, width / aspect)
    }

    // MARK: Helpers

    private static func interfaceFactor(_ interfaceScale: Int) -> Double {
        Double(clamp(interfaceScale, GraphicsSettings.interfaceScaleRange)) / 100
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The nearest multiple of `step`, ties away from zero.
    private static func nearest(_ value: Double, to step: Int) -> Int {
        Int((value / Double(step)).rounded()) * step
    }

    /// The multiple of `step` at or below `value` (a hair of tolerance, so
    /// 8192 × (8184 / 8192) does not fall to the next step down).
    private static func floor(_ value: Double, to step: Int) -> Int {
        Int((value / Double(step) + 1e-9).rounded(.down)) * step
    }
}
