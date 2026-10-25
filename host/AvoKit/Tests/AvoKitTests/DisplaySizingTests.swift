import Foundation
import Testing
@testable import AvoKit

// The worked values of the MetalFX plan (section 1): what a window asks
// Android for, and how its frame lands on screen.

private func follow(_ renderScale: Int, interface: Int = 100) -> GraphicsSettings {
    var settings = GraphicsSettings.appsDefault
    settings.renderScale = renderScale
    settings.interfaceScale = interface
    return settings
}

private func fixed(_ shortSide: Int, _ aspect: GraphicsSettings.AspectRatio, interface: Int = 100) -> GraphicsSettings {
    var settings = GraphicsSettings.gamesDefault
    settings.shortSide = shortSide
    settings.aspectRatio = aspect
    settings.interfaceScale = interface
    return settings
}

private func followRatio(_ renderScale: Int, _ aspect: GraphicsSettings.AspectRatio) -> GraphicsSettings {
    var settings = follow(renderScale)
    settings.followAspectRatio = aspect
    return settings
}

private func phone(interface: Int = 100) -> GraphicsSettings {
    var settings = GraphicsSettings.appsDefault
    settings.mode = .deviceProfile
    settings.interfaceScale = interface
    return settings
}

private let pixel = DeviceProfile.Display(width: 1080, height: 2400, dpi: 420)

private func request(_ width: Double, _ height: Double, _ settings: GraphicsSettings, backing: Double = 2,
                     device: DeviceProfile.Display? = nil, landscape: Bool? = nil) -> DisplayRequest {
    DisplaySizing.request(contentWidth: width, contentHeight: height, backingScale: backing, settings: settings, device: device,
                          landscape: landscape)
}

private func size(_ width: Int, _ height: Int) -> PixelSize { PixelSize(width: width, height: height) }

private func path(_ source: PixelSize, _ destination: PixelSize, _ filter: GraphicsSettings.Filter = .metalFXSpatial,
                  available: Bool = true, interactive: Bool = false) -> ScalingPath {
    DisplaySizing.scalingPath(source: source, destination: destination, filter: filter, metalFXAvailable: available, interactive: interactive)
}

@Suite struct DisplaySizingTests {
    @Test func followModeWorkedValues() {
        let native = request(412, 892, follow(100))
        #expect(native == DisplayRequest(width: 824, height: 1784, dpi: 320, effectiveRenderScale: 100))
        #expect(DisplaySizing.presentationRect(source: native.size, target: size(824, 1784)) == PixelRect(x: 0, y: 0, width: 824, height: 1784))
        #expect(path(native.size, size(824, 1784)) == .native)

        // One point wider: the width stays a multiple of 8 and the picture 1:1.
        let wider = request(413, 892, follow(100))
        #expect(wider.size == size(824, 1784))
        #expect(DisplaySizing.presentationRect(source: wider.size, target: size(826, 1784)) == PixelRect(x: 1, y: 0, width: 824, height: 1784))

        let ultra = request(412, 892, follow(77))
        #expect((ultra.size, ultra.dpi) == (size(632, 1374), 246))
        #expect(path(ultra.size, size(824, 1784)) == .metalFX(output: size(824, 1784)))

        let quality = request(892, 412, follow(67))
        #expect((quality.size, quality.dpi) == (size(1192, 552), 214))

        let balanced = request(412, 892, follow(59))
        #expect((balanced.size, balanced.dpi) == (size(488, 1052), 189))

        let performance = request(412, 892, follow(50))
        #expect((performance.size, performance.dpi, performance.effectiveRenderScale) == (size(416, 892), 160, 50))
        #expect(DisplaySizing.presentationRect(source: performance.size, target: size(824, 1784)) == PixelRect(x: 0, y: 0, width: 824, height: 1784))
        #expect(path(performance.size, size(824, 1784)) == .metalFX(output: size(824, 1784)))
    }

    @Test func densityFloorLimitsOneTimesScreens() {
        let r = request(412, 892, follow(50), backing: 1)
        #expect(r == DisplayRequest(width: 312, height: 670, dpi: 120, effectiveRenderScale: 75, limitedByDensity: true))
        #expect(path(r.size, size(412, 892)) == .metalFX(output: size(412, 892)))
    }

    @Test func interfaceSizeChangesOnlyTheLayout() {
        let r = request(412, 892, follow(100, interface: 115))
        #expect((r.size, r.dpi) == (size(824, 1784), 368))
        #expect(r.layoutDP == size(358, 776))
        // The layout is the same at every render scale, up to the rounding of
        // the size to multiples of 8 and 2 pixels.
        let layout = request(412, 892, follow(100)).layoutDP
        for preset in GraphicsSettings.RenderScalePreset.allCases {
            let scaled = request(412, 892, follow(preset.rawValue)).layoutDP
            #expect(abs(scaled.width - layout.width) <= 4 && abs(scaled.height - layout.height) <= 2, "\(preset)")
        }
    }

    @Test func fixedModeWorkedValues() {
        let landscape = request(892, 501.75, fixed(720, .ratio16x9))
        #expect(landscape == DisplayRequest(width: 1280, height: 720, dpi: 280))
        #expect(DisplaySizing.presentationRect(source: landscape.size, target: size(1784, 1004)) == PixelRect(x: 0, y: 0, width: 1784, height: 1004))
        #expect(path(landscape.size, size(1784, 1004)) == .metalFX(output: size(1784, 1004)))

        #expect(request(501.75, 892, fixed(720, .ratio16x9)).size == size(720, 1280))
        let small = request(412, 892, fixed(540, .ratio16x9))
        #expect((small.size, small.dpi) == (size(544, 968), 210))

        // Full screen on a 16:10 Mac: no re-plug, thin bars, MetalFX ×2.25.
        let fullScreen = request(1440, 900, fixed(720, .ratio16x9))
        #expect(fullScreen.size == size(1280, 720))
        #expect(!DisplaySizing.shouldReplug(current: landscape, proposed: fullScreen, windowAspect: 1.6, followsWindow: false))
        let bars = DisplaySizing.presentationRect(source: fullScreen.size, target: size(2880, 1800))
        #expect(bars == PixelRect(x: 0, y: 90, width: 2880, height: 1620))
        #expect(path(fullScreen.size, bars.size) == .metalFX(output: size(2880, 1620)))

        // 6K: MetalFX stops at ×4 and bilinear does the rest.
        let sixK = DisplaySizing.presentationRect(source: size(1280, 720), target: size(6016, 3384))
        #expect(sixK == PixelRect(x: 0, y: 0, width: 6016, height: 3384))
        #expect(path(size(1280, 720), sixK.size) == .metalFX(output: size(5120, 2880)))
    }

    @Test func matchWindowTakesTheWindowsShape() {
        let landscape = request(892, 412, fixed(720, .matchWindow))
        #expect((landscape.size, landscape.dpi) == (size(1560, 720), 280))
        #expect(DisplaySizing.presentationRect(source: landscape.size, target: size(1784, 824)) == PixelRect(x: 0, y: 0, width: 1784, height: 824))
        #expect(path(landscape.size, size(1784, 824)) == .metalFX(output: size(1784, 824)))

        let portrait = request(412, 892, fixed(720, .matchWindow))
        #expect((portrait.size, portrait.dpi) == (size(720, 1558), 280))

        let fullScreen = request(1440, 900, fixed(1080, .matchWindow))
        #expect((fullScreen.size, fullScreen.dpi) == (size(1728, 1080), 420))
        #expect(path(fullScreen.size, size(2880, 1800)) == .metalFX(output: size(2880, 1800)))
    }

    @Test func fixedModeIgnoresTheBackingScale() {
        for settings in [fixed(720, .ratio16x9), fixed(900, .matchWindow)] {
            #expect(request(892, 412, settings, backing: 1) == request(892, 412, settings, backing: 2))
        }
        // Rotation is the caller's choice for fixed ratios.
        #expect(request(892, 501.75, fixed(720, .ratio16x9), landscape: false).size == size(720, 1280))
    }

    @Test func automaticDensity() {
        let expected = [360: 140, 540: 210, 544: 210, 720: 280, 900: 350, 1080: 420, 1440: 560, 1600: 620]
        for (short, dpi) in expected {
            #expect(DisplaySizing.automaticDPI(shortSide: short, interfaceScale: 100) == dpi, "short side \(short)")
        }
        #expect(DisplaySizing.automaticDPI(shortSide: 720, interfaceScale: 130) == 360)
        let largest = request(1600, 900, fixed(1600, .ratio16x9, interface: 150))
        #expect(largest.dpi == 640)
        #expect(largest.limitedByDensity)
        // Below 600 dp on the short side for every allowed resolution: never a tablet layout.
        for short in stride(from: GraphicsSettings.shortSideRange.lowerBound, through: GraphicsSettings.shortSideRange.upperBound, by: 2) {
            let dpi = DisplaySizing.automaticDPI(shortSide: short, interfaceScale: 100)
            #expect(Double(short) * 160 / Double(dpi) < 600)
        }
    }

    @Test func minimumRenderScale() {
        #expect(DisplaySizing.minimumRenderScale(backingScale: 2, interfaceScale: 100) == 38)
        #expect(DisplaySizing.minimumRenderScale(backingScale: 1, interfaceScale: 100) == 75)
        #expect(DisplaySizing.minimumRenderScale(backingScale: 1, interfaceScale: 85) == 89)
    }

    @Test func sizeLimits() {
        let wide = request(3000, 240, fixed(1600, .matchWindow))
        #expect(wide == DisplayRequest(width: 8192, height: 654, dpi: 250, limitedBySize: true))

        // A small window: the 240-px short side raises the render scale.
        let small = request(200, 400, follow(50))
        #expect(small == DisplayRequest(width: 240, height: 480, dpi: 192, effectiveRenderScale: 60, limitedBySize: true))
    }

    @Test func replugRules() {
        let current = request(892, 412, fixed(720, .matchWindow))
        #expect(current.size == size(1560, 720))
        func replugs(_ width: Double, _ height: Double, _ settings: GraphicsSettings = fixed(720, .matchWindow),
                     follows: Bool = false) -> Bool {
            DisplaySizing.shouldReplug(current: current, proposed: request(width, height, settings), windowAspect: width / height,
                                       followsWindow: follows)
        }
        #expect(!replugs(896, 412))                 // 0.4% off: stretched
        #expect(replugs(904, 412))                  // 1.3% off: re-plug
        #expect(replugs(892, 412, fixed(1080, .matchWindow)))           // short side
        #expect(replugs(892, 412, fixed(720, .matchWindow, interface: 115)))  // density
        #expect(!replugs(892, 412))                 // identical
        #expect(DisplaySizing.shouldReplug(current: nil, proposed: current, windowAspect: 2, followsWindow: false))

        // Follow mode takes every change.
        let window = request(412, 892, follow(100))
        #expect(DisplaySizing.shouldReplug(current: window, proposed: request(420, 892, follow(100)), windowAspect: 420.0 / 892,
                                           followsWindow: true))
        #expect(!DisplaySizing.shouldReplug(current: window, proposed: window, windowAspect: 412.0 / 892, followsWindow: true))

        // A fixed ratio: full screen keeps it, rotating re-plugs.
        let ratio = request(892, 501.75, fixed(720, .ratio16x9))
        #expect(!DisplaySizing.shouldReplug(current: ratio, proposed: request(1440, 900, fixed(720, .ratio16x9)), windowAspect: 1.6,
                                            followsWindow: false))
        #expect(DisplaySizing.shouldReplug(current: ratio, proposed: request(892, 501.75, fixed(720, .ratio16x9), landscape: false),
                                           windowAspect: 501.75 / 892, followsWindow: false))

        // The smallest resolution: a square window, then one point wider.
        let square = request(360, 360, fixed(360, .matchWindow))
        #expect(!DisplaySizing.shouldReplug(current: square, proposed: request(361, 360, fixed(360, .matchWindow)),
                                            windowAspect: 361.0 / 360, followsWindow: false))
    }

    @Test func toleranceCoversRounding() {
        // A presented picture is off by at most the re-plug tolerance (no
        // re-plug yet) or a fresh request's rounding (≤ 4/long + 1/short,
        // 1.4% at 360 px); both must be stretched, never barred.
        #expect(DisplaySizing.fillTolerance >= max(DisplaySizing.replugTolerance, 4.0 / 360 + 1.0 / 360))
    }

    @Test func presentationRects() {
        let target = size(1784, 824)
        #expect(DisplaySizing.presentationRect(source: size(824, 1784), target: size(826, 1784)) == PixelRect(x: 1, y: 0, width: 824, height: 1784))
        #expect(DisplaySizing.presentationRect(source: size(1560, 720), target: target) == PixelRect(x: 0, y: 0, width: 1784, height: 824))
        #expect(DisplaySizing.presentationRect(source: size(1560, 720), target: size(1784, 1000)) == PixelRect(x: 0, y: 88, width: 1784, height: 823))
        #expect(DisplaySizing.presentationRect(source: size(1280, 720), target: size(2880, 1800)) == PixelRect(x: 0, y: 90, width: 2880, height: 1620))
        #expect(DisplaySizing.presentationRect(source: size(416, 892), target: size(824, 1784)) == PixelRect(x: 0, y: 0, width: 824, height: 1784))
        #expect(DisplaySizing.presentationRect(source: size(0, 0), target: target) == PixelRect(x: 0, y: 0, width: 1784, height: 824))
        #expect(DisplaySizing.presentationRect(source: size(1280, 720), target: size(0, 0)) == PixelRect(x: 0, y: 0, width: 0, height: 0))
    }

    @Test func scalingPaths() {
        let source = size(1280, 720)
        #expect(path(source, size(1464, 824)) == .metalFX(output: size(1464, 824)))
        #expect(path(source, size(6016, 3384)) == .metalFX(output: size(5120, 2880)))
        #expect(path(source, size(1464, 824), interactive: true) == .bilinear)
        #expect(path(source, size(1464, 824), available: false) == .bilinear)
        #expect(path(size(1000, 1000), size(1020, 1020)) == .bilinear)   // ×1.02: MetalFX would not show
        #expect(path(source, size(1464, 824), .bilinear) == .bilinear)
        #expect(path(source, size(2560, 1440), .nearest) == .nearest)
        #expect(path(size(2336, 1080), size(1784, 824)) == .downsample(taps: 2))
        #expect(path(size(4000, 4000), size(500, 500)) == .downsample(taps: 4))
        #expect(path(size(1000, 1000), size(1200, 900)) == .bilinear)    // mixed axes
        #expect(path(source, source) == .native)
    }

    @Test func followModeWithAFixedRatio() {
        // A window locked to 16:9: Android takes all of it, 1:1 at 100%.
        let window = request(892, 501.75, followRatio(100, .ratio16x9))
        #expect(window == DisplayRequest(width: 1784, height: 1002, dpi: 320, effectiveRenderScale: 100))
        #expect(DisplaySizing.presentationRect(source: window.size, target: size(1784, 1004)) == PixelRect(x: 0, y: 1, width: 1784, height: 1002))
        // Render scales still apply, at the window's shape.
        let quality = request(892, 501.75, followRatio(67, .ratio16x9))
        #expect((quality.size, quality.dpi) == (size(1192, 672), 214))
        // Full screen on a 16:10 Mac keeps 16:9, with bars, at the screen's pixels.
        let fullScreen = request(1440, 900, followRatio(100, .ratio16x9), landscape: true)
        #expect(fullScreen.size == size(2880, 1620))
        #expect(DisplaySizing.presentationRect(source: fullScreen.size, target: size(2880, 1800)) == PixelRect(x: 0, y: 90, width: 2880, height: 1620))
        #expect(path(fullScreen.size, size(2880, 1620)) == .native)
        // Turned to portrait, in the same full screen.
        #expect(request(1440, 900, followRatio(100, .ratio16x9), landscape: false).size == size(1008, 1800))
        // Match window: the whole window, whatever its shape.
        #expect(request(1440, 900, followRatio(100, .matchWindow), landscape: false).size == size(2880, 1800))
    }

    @Test func fittedContentSize() {
        let bars = DisplaySizing.fittedContentSize(width: 1440, height: 900, longOverShort: 16.0 / 9, landscape: true)
        #expect(bars.width == 1440 && bars.height == 810)
        let portrait = DisplaySizing.fittedContentSize(width: 1440, height: 900, longOverShort: 16.0 / 9, landscape: false)
        #expect(portrait.width == 506.25 && portrait.height == 900)
        // A window locked to the ratio, up to a point's rounding: kept whole.
        let window = DisplaySizing.fittedContentSize(width: 892, height: 502, longOverShort: 16.0 / 9, landscape: true)
        #expect(window.width == 892 && window.height == 502)
    }

    @Test func phoneScreen() {
        // The phone's pixels at its density, whatever the window, the backing
        // scale or the interface size: apps lay out as on the phone.
        let portrait = request(412, 892, phone(), device: pixel)
        #expect(portrait == DisplayRequest(width: 1080, height: 2400, dpi: 420))
        #expect(portrait.layoutDP == size(411, 914))
        #expect(request(412, 892, phone(interface: 130), backing: 1, device: pixel) == portrait)
        #expect(request(892, 412, phone(), device: pixel).size == size(2400, 1080))
        #expect(request(412, 892, phone(), device: pixel, landscape: true).size == size(2400, 1080))
        // Widths become multiples of 8; a density beyond Android's is clamped.
        let poco = DeviceProfile.Display(width: 1220, height: 2712, dpi: 446)
        #expect(request(412, 892, phone(), device: poco).size == size(1216, 2712))
        #expect(request(892, 412, phone(), device: poco).size == size(2712, 1220))
        #expect(request(892, 412, phone(), device: .init(width: 1084, height: 2412, dpi: 394)).size == size(2408, 1084))
        let dense = request(412, 892, phone(), device: .init(width: 1440, height: 3200, dpi: 700))
        #expect((dense.dpi, dense.limitedByDensity) == (640, true))
        // A device profile without a screen (Avo's own): Android follows the window.
        #expect(request(412, 892, phone(), device: nil) == request(412, 892, follow(100)))
        // Rotating re-plugs; full screen keeps the phone's screen.
        let landscape = request(892, 401, phone(), device: pixel, landscape: true)
        #expect(DisplaySizing.shouldReplug(current: portrait, proposed: landscape, windowAspect: 2400.0 / 1080, followsWindow: false))
        #expect(!DisplaySizing.shouldReplug(current: landscape, proposed: request(1440, 900, phone(), device: pixel, landscape: true),
                                            windowAspect: 2400.0 / 1080, followsWindow: false))
    }

    /// Supersampling: Android renders more pixels at the same layout, and the renderer shrinks them.
    @Test func supersampling() {
        func smoothed(_ settings: GraphicsSettings, _ value: GraphicsSettings.AntiAliasing) -> GraphicsSettings {
            var settings = settings
            settings.antiAliasing = value
            return settings
        }
        // Follow mode: 824 × 1784 at 320 dpi, twice each side at 640 dpi: the same 412 × 892 dp.
        let native = request(412, 892, follow(100))
        let four = request(412, 892, smoothed(follow(100), .ssaa4x))
        #expect(four == DisplayRequest(width: 1648, height: 3568, dpi: 640, effectiveRenderScale: 100))
        #expect(four.layoutDP == native.layoutDP)
        #expect(path(four.size, size(824, 1784)) == .downsample(taps: 2))
        // √2 each side: the width in steps of 8, the height and density following it.
        let two = request(412, 892, smoothed(follow(100), .ssaa2x))
        #expect((two.size, two.dpi) == (size(1160, 2510), 450))
        #expect(two.layoutDP == native.layoutDP)
        // Fixed mode, and the phone's screen past Android's 640 dpi.
        #expect(request(892, 501.75, smoothed(fixed(720, .ratio16x9), .ssaa4x)) == DisplayRequest(width: 2560, height: 1440, dpi: 560))
        #expect(request(412, 892, smoothed(phone(), .ssaa4x), device: pixel) == DisplayRequest(width: 2160, height: 4800, dpi: 840))
        // FXAA is the renderer's alone.
        #expect(request(412, 892, smoothed(follow(100), .fxaa)) == native)
        // Stopped at the largest display, and said so.
        let fiveK = request(2560, 1440, smoothed(follow(100), .ssaa4x))
        #expect((fiveK.size, fiveK.dpi, fiveK.limitedBySize) == (size(8192, 4608), 512, true))
    }

    @Test func fourK() {
        let uhd = request(1600, 900, fixed(2160, .ratio16x9))
        #expect(uhd == DisplayRequest(width: 3840, height: 2160, dpi: 640, limitedByDensity: true))
        #expect(uhd.layoutDP == size(960, 540))
        #expect(request(900, 1600, fixed(2160, .ratio16x9)).size == size(2160, 3840))
        #expect(request(1600, 720, fixed(2160, .ratio20x9)).size == size(4800, 2160))
        #expect(DisplaySizing.automaticDPI(shortSide: 2160, interfaceScale: 100) == 640)
        #expect(DisplaySizing.automaticDPI(shortSide: 2160, interfaceScale: 75) == 630)
        // Shown on a 5K display: no scaling needed but shrinking in a smaller window.
        #expect(path(uhd.size, size(3840, 2160)) == .native)
        #expect(path(uhd.size, size(1784, 1004)) == .downsample(taps: 3))
    }

    @Test func lockedRatios() {
        #expect(GraphicsSettings.appsDefault.lockedRatio(device: pixel) == nil)
        #expect(GraphicsSettings.gamesDefault.lockedRatio(device: nil) == 16.0 / 9)
        #expect(followRatio(100, .ratio16x10).lockedRatio(device: nil) == 1.6)
        #expect(phone().lockedRatio(device: pixel) == 2400.0 / 1080)
        // Without a screen to copy, the phone's mode follows the window, free.
        #expect(phone().lockedRatio(device: nil) == nil)
        #expect(phone().effectiveMode(device: nil) == .followWindow)
        #expect(phone().effectiveMode(device: pixel) == .deviceProfile)
        var settings = GraphicsSettings.gamesDefault
        settings.setAspectRatio(.ratio4x3, for: .followWindow)
        #expect((settings.followAspectRatio, settings.aspectRatio) == (.ratio4x3, .ratio16x9))
        settings.setAspectRatio(.matchWindow, for: .fixed)
        #expect(settings.aspectRatio(for: .fixed) == .matchWindow && settings.aspectRatio(for: .followWindow) == .ratio4x3)
    }

    @Test func conformedContentSize() {
        let landscape = DisplaySizing.conformedContentSize(width: 892, height: 412, longOverShort: 16.0 / 9)
        #expect(landscape.width == 892 && abs(landscape.height - 501.75) < 1e-9)
        let portrait = DisplaySizing.conformedContentSize(width: 412, height: 892, longOverShort: 16.0 / 9)
        #expect(abs(portrait.width - 501.75) < 1e-9 && portrait.height == 892)
    }

    /// A press beside the picture (the bars of a frame that does not fill
    /// the window) moves the window; on the picture, or just at its edge,
    /// it touches Android.
    @Test func pressesBesideThePictureMoveTheWindow() {
        // A portrait frame fitted into a wide window: bars left and right.
        let picture = CGRect(x: 300, y: 0, width: 400, height: 800)
        #expect(!DisplaySizing.movesWindow(at: CGPoint(x: 500, y: 400), picture: picture), "on the picture")
        #expect(!DisplaySizing.movesWindow(at: CGPoint(x: 297, y: 400), picture: picture), "just at its edge")
        #expect(DisplaySizing.movesWindow(at: CGPoint(x: 100, y: 400), picture: picture), "in the left bar")
        #expect(DisplaySizing.movesWindow(at: CGPoint(x: 900, y: 10), picture: picture), "in the right bar")
        // A frame that fills the window leaves nothing to move it by.
        let full = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(!DisplaySizing.movesWindow(at: CGPoint(x: 0.5, y: 799), picture: full))
    }
}
