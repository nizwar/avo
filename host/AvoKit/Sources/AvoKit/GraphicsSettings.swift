import Foundation

// Graphics settings of app windows (Control Panel › Graphics, a window's View
// menu): how Android's screen is sized (following the window, a fixed
// resolution, or the device profile's phone screen), its shape and
// orientation, how large its interface is, and how the Window Host scales the
// picture to the window. There are two default profiles, Apps and Games,
// plus sparse per-app overrides that store only the fields the user changed,
// so an app keeps following later edits of its profile. The sizing math
// lives in DisplaySizing.swift.

/// The default settings an app starts from.
public enum GraphicsProfile: String, Codable, CaseIterable, Sendable {
    case apps
    case games
}

public struct GraphicsSettings: Codable, Equatable, Hashable, Sendable {
    /// How Android's screen is sized.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// "Follow window": the window's pixels × `renderScale`, in
        /// `followAspectRatio`'s shape.
        case followWindow
        /// "Fixed resolution": `shortSide` × `aspectRatio`.
        case fixed
        /// "Phone's screen": the device profile's display, its width ×
        /// height at its dpi, so apps lay out as on that phone. The
        /// interface size does not apply. Without a display (Avo's own
        /// identity has none) Android follows the window (`effectiveMode`).
        case deviceProfile
    }

    /// How the Window Host enlarges Android's picture. Shrinking always uses
    /// an area filter, whatever is chosen here.
    public enum Filter: String, Codable, CaseIterable, Sendable {
        /// Apple's MetalFX spatial upscaler (`MTLFXSpatialScaler`).
        case metalFXSpatial
        case bilinear
        /// Square, crisp pixels, for pixel art.
        case nearest
    }

    /// Smoothing jagged edges: in the Window Host's renderer, or by Android
    /// rendering more pixels than the window shows.
    public enum AntiAliasing: String, Codable, CaseIterable, Sendable {
        case off
        /// Fast approximate anti-aliasing on Android's frame, before it is scaled.
        case fxaa
        /// Supersampling: Android renders 2 or 4 times the pixels (√2 or 2
        /// times each side, the density too, so the layout stays), and the
        /// renderer shrinks the frame to the window.
        case ssaa2x
        case ssaa4x

        /// How many times each side Android renders.
        public var supersampling: Double {
            switch self {
            case .off, .fxaa: 1
            case .ssaa2x: 2.squareRoot()
            case .ssaa4x: 2
            }
        }
    }

    /// The shape of Android's screen: of the window in follow mode, of the
    /// fixed resolution in fixed mode.
    public enum AspectRatio: String, Codable, CaseIterable, Sendable {
        /// Android takes the window's shape (re-plugging once when it
        /// changes, in fixed mode), and the window resizes freely.
        case matchWindow
        case ratio16x9 = "16:9"
        case ratio16x10 = "16:10"
        case ratio20x9 = "20:9"
        case ratio4x3 = "4:3"

        /// The long side over the short side; nil for `matchWindow`.
        public var longOverShort: Double? {
            switch self {
            case .matchWindow: nil
            case .ratio16x9: 16.0 / 9
            case .ratio16x10: 16.0 / 10
            case .ratio20x9: 20.0 / 9
            case .ratio4x3: 4.0 / 3
            }
        }
    }

    /// How Android's screen is sized. Files saved before the phone's screen
    /// had `followsWindow` (true or false) instead, which is still read
    /// (GraphicsSettingsPatch) but no longer written.
    public var mode: Mode
    /// Percent of the window's pixels Android renders (follow mode).
    public var renderScale: Int
    /// Pixels on the short side of Android's screen (fixed mode), even.
    public var shortSide: Int
    /// Fixed mode's shape.
    public var aspectRatio: AspectRatio
    /// Follow mode's shape: a ratio locks the window to it while Android
    /// still renders the window's pixels × `renderScale`; Match window leaves
    /// the window free. A field of its own, because `aspectRatio` was fixed
    /// mode's alone in older files.
    public var followAspectRatio: AspectRatio
    /// The shape an app's first window opens in, and the one a fixed shape
    /// (a ratio, the phone's screen) keeps until the app asks for the other
    /// one or the window is rotated.
    public var orientation: VMConfig.Orientation
    /// Percent; 100 makes 1 Android dp the size of 1 Mac point. Avo derives
    /// the density from it in follow and fixed mode, so the resolution and
    /// render scale change sharpness, never the layout (up to Android's
    /// 640 dpi, which fixed resolutions above 1600 px reach).
    public var interfaceScale: Int
    public var filter: Filter
    /// Adaptive sharpening after scaling, 0...100; 0 is off.
    public var sharpness: Int
    public var antiAliasing: AntiAliasing

    public init(mode: Mode, renderScale: Int, shortSide: Int, aspectRatio: AspectRatio, followAspectRatio: AspectRatio = .matchWindow,
                orientation: VMConfig.Orientation = .portrait, interfaceScale: Int, filter: Filter, sharpness: Int,
                antiAliasing: AntiAliasing = .off) {
        self.mode = mode
        self.renderScale = renderScale
        self.shortSide = shortSide
        self.aspectRatio = aspectRatio
        self.followAspectRatio = followAspectRatio
        self.orientation = orientation
        self.interfaceScale = interfaceScale
        self.filter = filter
        self.sharpness = sharpness
        self.antiAliasing = antiAliasing
    }

    /// Apps: sharp text at the window's own resolution, in portrait.
    public static let appsDefault = GraphicsSettings(mode: .followWindow, renderScale: 100, shortSide: 1080, aspectRatio: .matchWindow,
                                                     orientation: .portrait, interfaceScale: 100, filter: .metalFXSpatial, sharpness: 0)
    /// Games: Android renders in software on the Mac's CPU, so a fixed 720p
    /// 16:9 landscape screen enlarged with MetalFX runs faster, and the
    /// fixed shape never makes the game lay out again when the window changes.
    public static let gamesDefault = GraphicsSettings(mode: .fixed, renderScale: 67, shortSide: 720, aspectRatio: .ratio16x9,
                                                      orientation: .landscape, interfaceScale: 100, filter: .metalFXSpatial, sharpness: 0)

    public static let renderScaleRange = 50...100
    /// Up to 4K (2160p).
    public static let shortSideRange = 360...2160
    /// Smaller and larger values only come from migrated densities or avoctl.
    public static let interfaceScaleRange = 75...150
    public static let sharpnessRange = 0...100
    public static let sharpnessStep = 5
    public static let resolutionPresets = [540, 720, 900, 1080, 1440, 2160]
    /// Android renders more pixels than this (a 1440p 16:9 screen has
    /// 3.7 million) slowly with the Software renderer: the editor says so.
    public static let softwareRenderingPixelBudget = 3_200_000

    /// "720p", and "4K" for 2160p.
    public static func resolutionName(_ shortSide: Int) -> String {
        shortSide == 2160 ? "4K" : "\(shortSide)p"
    }

    /// The mode in effect: the phone's screen needs a device profile with a
    /// display (`VMConfig.deviceDisplay(in:)`); without one Android follows
    /// the window.
    public func effectiveMode(device: DeviceProfile.Display?) -> Mode {
        mode == .deviceProfile && device == nil ? .followWindow : mode
    }

    /// The shape the window is locked to, long side over short; nil while it
    /// resizes freely (Match window). The phone's screen keeps the phone's shape.
    public func lockedRatio(device: DeviceProfile.Display?) -> Double? {
        switch effectiveMode(device: device) {
        case .followWindow: followAspectRatio.longOverShort
        case .fixed: aspectRatio.longOverShort
        case .deviceProfile: device.map(\.longOverShort)
        }
    }

    /// What the Aspect ratio control shows in `mode`: follow mode's or fixed
    /// mode's (the phone's screen has the phone's, `lockedRatio`).
    public func aspectRatio(for mode: Mode) -> AspectRatio {
        mode == .followWindow ? followAspectRatio : aspectRatio
    }

    public mutating func setAspectRatio(_ ratio: AspectRatio, for mode: Mode) {
        if mode == .followWindow { followAspectRatio = ratio } else { aspectRatio = ratio }
    }

    /// FSR-style quality presets, in percent.
    public enum RenderScalePreset: Int, CaseIterable, Sendable {
        case native = 100
        case ultraQuality = 77
        case quality = 67
        case balanced = 59
        case performance = 50
    }

    /// In percent.
    public enum InterfaceSizePreset: Int, CaseIterable, Sendable {
        case smaller = 85
        case standard = 100
        case larger = 115
        case largest = 130
    }

    /// A file may hold any subset of the fields, of any type: what is missing
    /// or unreadable takes the Apps default (`VMConfig` applies the profile's
    /// own default instead).
    public init(from decoder: any Decoder) throws {
        self = try GraphicsSettingsPatch(from: decoder).applied(to: .appsDefault)
    }

    /// Errors for values outside the ranges above. Field names are
    /// `<prefix>.renderScale`, `.shortSide`, `.interfaceScale` and `.sharpness`;
    /// the Control Panel shows each one under its own control.
    public func validate(field prefix: String) -> [ConfigIssue] {
        Self.issues(prefix: prefix, renderScale: renderScale, shortSide: shortSide, interfaceScale: interfaceScale, sharpness: sharpness)
    }

    static func issues(prefix: String, renderScale: Int?, shortSide: Int?, interfaceScale: Int?, sharpness: Int?) -> [ConfigIssue] {
        var issues: [ConfigIssue] = []
        func error(_ field: String, _ message: String) {
            issues.append(ConfigIssue(field: "\(prefix).\(field)", severity: .error, message: message))
        }
        if let renderScale, !renderScaleRange.contains(renderScale) {
            let (low, high) = (renderScaleRange.lowerBound, renderScaleRange.upperBound)
            error("renderScale", String(localized: "The render scale must be between \(low)% and \(high)%.", bundle: .avoKit))
        }
        if let shortSide, !shortSideRange.contains(shortSide) || !shortSide.isMultiple(of: 2) {
            // Strings: resolutions are never digit-grouped ("2.160").
            let (low, high) = (String(shortSideRange.lowerBound), String(shortSideRange.upperBound))
            error("shortSide", String(localized: "The resolution must be an even number between \(low) and \(high) pixels on the short side.",
                                      bundle: .avoKit))
        }
        if let interfaceScale, !interfaceScaleRange.contains(interfaceScale) {
            let (low, high) = (interfaceScaleRange.lowerBound, interfaceScaleRange.upperBound)
            error("interfaceScale", String(localized: "The interface size must be between \(low)% and \(high)%.", bundle: .avoKit))
        }
        if let sharpness, !sharpnessRange.contains(sharpness) {
            error("sharpness", String(localized: "Sharpness must be between 0 and 100.", bundle: .avoKit))
        }
        return issues
    }
}

/// Only the fields that differ from a profile; nil fields follow it.
public struct GraphicsSettingsPatch: Codable, Equatable, Hashable, Sendable {
    public var mode: GraphicsSettings.Mode?
    public var renderScale: Int?
    public var shortSide: Int?
    public var aspectRatio: GraphicsSettings.AspectRatio?
    public var followAspectRatio: GraphicsSettings.AspectRatio?
    public var orientation: VMConfig.Orientation?
    public var interfaceScale: Int?
    public var filter: GraphicsSettings.Filter?
    public var sharpness: Int?
    public var antiAliasing: GraphicsSettings.AntiAliasing?

    public init() {}

    public var isEmpty: Bool { count == 0 }

    /// How many fields the patch changes.
    public var count: Int {
        let fields: [Any?] = [mode, renderScale, shortSide, aspectRatio, followAspectRatio, orientation, interfaceScale, filter, sharpness,
                              antiAliasing]
        return fields.count(where: { $0 != nil })
    }

    public func applied(to base: GraphicsSettings) -> GraphicsSettings {
        var settings = base
        if let mode { settings.mode = mode }
        if let renderScale { settings.renderScale = renderScale }
        if let shortSide { settings.shortSide = shortSide }
        if let aspectRatio { settings.aspectRatio = aspectRatio }
        if let followAspectRatio { settings.followAspectRatio = followAspectRatio }
        if let orientation { settings.orientation = orientation }
        if let interfaceScale { settings.interfaceScale = interfaceScale }
        if let filter { settings.filter = filter }
        if let sharpness { settings.sharpness = sharpness }
        if let antiAliasing { settings.antiAliasing = antiAliasing }
        return settings
    }

    /// The fields of `settings` that differ from `base`.
    public static func difference(_ settings: GraphicsSettings, from base: GraphicsSettings) -> GraphicsSettingsPatch {
        var patch = GraphicsSettingsPatch()
        if settings.mode != base.mode { patch.mode = settings.mode }
        if settings.renderScale != base.renderScale { patch.renderScale = settings.renderScale }
        if settings.shortSide != base.shortSide { patch.shortSide = settings.shortSide }
        if settings.aspectRatio != base.aspectRatio { patch.aspectRatio = settings.aspectRatio }
        if settings.followAspectRatio != base.followAspectRatio { patch.followAspectRatio = settings.followAspectRatio }
        if settings.orientation != base.orientation { patch.orientation = settings.orientation }
        if settings.interfaceScale != base.interfaceScale { patch.interfaceScale = settings.interfaceScale }
        if settings.filter != base.filter { patch.filter = settings.filter }
        if settings.sharpness != base.sharpness { patch.sharpness = settings.sharpness }
        if settings.antiAliasing != base.antiAliasing { patch.antiAliasing = settings.antiAliasing }
        return patch
    }

    /// Like `GraphicsSettings.validate(field:)`, for the fields present only:
    /// one app's change is never refused because of anything else.
    public func validate(field prefix: String) -> [ConfigIssue] {
        GraphicsSettings.issues(prefix: prefix, renderScale: renderScale, shortSide: shortSide, interfaceScale: interfaceScale,
                                sharpness: sharpness)
    }

    private enum CodingKeys: String, CodingKey {
        case mode, renderScale, shortSide, aspectRatio, followAspectRatio, orientation, interfaceScale, filter, sharpness, antiAliasing
    }

    /// Read, never written: before the phone's screen, files said whether
    /// Android follows the window. `mode` wins when both are there.
    private enum LegacyKeys: String, CodingKey {
        case followsWindow
    }

    /// Each field on its own: a wrong type or an unknown value (from a newer
    /// Avo, avoctl or a hand edit) drops that field, never the whole file.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func field<T: Decodable>(_ key: CodingKeys) -> T? { try? container.decodeIfPresent(T.self, forKey: key) }
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        let followsWindow = try? legacy.decodeIfPresent(Bool.self, forKey: .followsWindow)
        mode = (field(.mode) as String?).flatMap(GraphicsSettings.Mode.init(rawValue:))
            ?? followsWindow.map { $0 ? .followWindow : .fixed }
        renderScale = field(.renderScale)
        shortSide = field(.shortSide)
        aspectRatio = (field(.aspectRatio) as String?).flatMap(GraphicsSettings.AspectRatio.init(rawValue:))
        followAspectRatio = (field(.followAspectRatio) as String?).flatMap(GraphicsSettings.AspectRatio.init(rawValue:))
        orientation = (field(.orientation) as String?).flatMap(VMConfig.Orientation.init(rawValue:))
        interfaceScale = field(.interfaceScale)
        filter = (field(.filter) as String?).flatMap(GraphicsSettings.Filter.init(rawValue:))
        sharpness = field(.sharpness)
        antiAliasing = (field(.antiAliasing) as String?).flatMap(GraphicsSettings.AntiAliasing.init(rawValue:))
    }
}

/// One app's own graphics settings (VMConfig.graphicsOverrides).
public struct AppGraphicsOverride: Codable, Equatable, Sendable {
    /// nil is automatic: Games when the app has a key mapping, else Apps.
    public var profile: GraphicsProfile?
    public var changes: GraphicsSettingsPatch

    public init(profile: GraphicsProfile? = nil, changes: GraphicsSettingsPatch = .init()) {
        self.profile = profile
        self.changes = changes
    }

    /// Nothing differs from the automatic choice; stored as no override.
    public var isEmpty: Bool { profile == nil && changes.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case profile, changes
    }

    /// An unknown profile becomes automatic; missing changes are none.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profile = (try? container.decodeIfPresent(String.self, forKey: .profile)).flatMap(GraphicsProfile.init(rawValue:))
        changes = (try? container.decodeIfPresent(GraphicsSettingsPatch.self, forKey: .changes)) ?? GraphicsSettingsPatch()
    }
}

/// The performance overlay in app windows. It is a view above the picture,
/// so it never appears in Avo's screenshots or recordings.
public enum PerformanceHUDLevel: String, Codable, CaseIterable, Sendable {
    case off
    case fps
    case detailed
}

/// The settings one app's windows use, and why.
public struct ResolvedGraphics: Equatable, Sendable {
    public enum Reason: Sendable {
        /// The user picked the profile for this app.
        case chosen
        /// Games, because the app has a usable key mapping.
        case keyMapping
        /// Games, because the app says it is one (its manifest's category),
        /// turned to the orientation the app asks for.
        case androidGame
        /// Apps: nothing chose otherwise.
        case none
    }

    public var settings: GraphicsSettings
    public var profile: GraphicsProfile
    public var reason: Reason
    /// What this app changes on top of `base` (empty when nothing).
    public var changes: GraphicsSettingsPatch
    /// What `changes` apply to: `profile`'s settings, in the app's own
    /// orientation when Android's word chose Games (`androidGame`).
    public var base: GraphicsSettings

    /// `base`: `settings` when nil (no changes).
    public init(settings: GraphicsSettings, profile: GraphicsProfile, reason: Reason, changes: GraphicsSettingsPatch,
                base: GraphicsSettings? = nil) {
        self.settings = settings
        self.profile = profile
        self.reason = reason
        self.changes = changes
        self.base = base ?? settings
    }
}

extension DeviceProfile.Display {
    /// The long side over the short one.
    public var longOverShort: Double {
        Double(max(width, height)) / Double(max(min(width, height), 1))
    }

    /// "20:9": the nearest common screen shape within 1%, else the long
    /// side per 9 of the short ("20.3:9"), written as phones are.
    public var ratioName: String {
        let ratio = longOverShort
        let common: [(ratio: Double, name: String)] = [(16.0 / 9, "16:9"), (18.0 / 9, "18:9"), (19.0 / 9, "19:9"), (19.5 / 9, "19.5:9"),
                                                       (20.0 / 9, "20:9"), (21.0 / 9, "21:9"), (16.0 / 10, "16:10"), (4.0 / 3, "4:3"),
                                                       (3.0 / 2, "3:2")]
        if let nearest = common.min(by: { abs($0.ratio / ratio - 1) < abs($1.ratio / ratio - 1) }), abs(nearest.ratio / ratio - 1) <= 0.01 {
            return nearest.name
        }
        let nines = (ratio * 9 * 10).rounded() / 10
        return nines == nines.rounded() ? "\(Int(nines)):9" : String(format: "%.1f:9", nines)
    }
}

extension VMConfig {
    /// The chosen device profile's screen, which "Phone's screen" gives
    /// Android; nil when the profile has none (Avo's own identity).
    public func deviceDisplay(in profiles: [DeviceProfile]) -> DeviceProfile.Display? {
        profiles.first { $0.id == deviceProfileID }?.display
    }

    public func settings(for profile: GraphicsProfile) -> GraphicsSettings {
        switch profile {
        case .apps: appGraphics
        case .games: gameGraphics
        }
    }

    /// The override's profile, else Games when the app has a key mapping
    /// (`KeymapProfile.usable(for:bundledDirectory:)`), else Apps; then the
    /// override's changes on top.
    /// `isGame`: Android lists the app as a game (AppRecord.isGame); a key
    /// mapping, and the user's choice before it, come first. Such a game
    /// keeps the Games profile's performance settings but opens in
    /// `orientation`, the one it asks for (AppRecord.orientation), so a
    /// portrait game is not turned; one that lets the screen turn takes the
    /// profile's.
    public func graphics(for package: String, hasKeyMapping: Bool, isGame: Bool = false,
                         orientation: VMConfig.Orientation? = nil) -> ResolvedGraphics {
        let override = graphicsOverrides[package]
        let profile: GraphicsProfile
        let reason: ResolvedGraphics.Reason
        if let chosen = override?.profile {
            profile = chosen
            reason = .chosen
        } else if hasKeyMapping {
            profile = .games
            reason = .keyMapping
        } else if isGame {
            profile = .games
            reason = .androidGame
        } else {
            profile = .apps
            reason = ResolvedGraphics.Reason.none
        }
        var base = settings(for: profile)
        if reason == .androidGame, let orientation { base.orientation = orientation }
        let changes = override?.changes ?? GraphicsSettingsPatch()
        return ResolvedGraphics(settings: changes.applied(to: base), profile: profile, reason: reason, changes: changes, base: base)
    }

    /// Display 0's density at boot. Nobody sees display 0, but Android sizes
    /// some resources from it: nil keeps what Android used before interface
    /// sizes existed (320, or the device profile's dpi), any other interface
    /// size scales 320 with it.
    public var bootDensity: Int? {
        let scale = min(max(appGraphics.interfaceScale, GraphicsSettings.interfaceScaleRange.lowerBound),
                        GraphicsSettings.interfaceScaleRange.upperBound)
        guard scale != 100 else { return nil }
        return Int((320 * Double(scale) / 100).rounded())
    }
}
