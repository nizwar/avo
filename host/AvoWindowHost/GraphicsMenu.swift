import AppKit
import AvoKit

/// What the View menu shows for the window in front (AndroidWindowController).
struct GraphicsMenuMode {
    /// "Game Settings, changed for this app".
    var profileLine: String
    /// The mode in effect.
    var mode: GraphicsSettings.Mode
    /// The device profile's screen's shape ("20:9"), shown in place of the aspect ratios in its mode.
    var phoneRatio: String?
}

/// The graphics part of the View menu: profile, how Android's screen is
/// sized, its shape and orientation, the scaling filter and the performance
/// HUD of the window in front. The actions are
/// nil-targeted, so they reach that window's AndroidWindowController, which
/// also validates them (checkmarks, enabled state). Items that do not apply
/// to the current mode are hidden rather than disabled, which only the menu
/// delegate can do, so it asks the window for that when the menu opens.
@MainActor
final class GraphicsMenu: NSObject, NSMenuDelegate {
    static let shared = GraphicsMenu()

    static let profileLine = NSUserInterfaceItemIdentifier("avo.graphics.profile")
    static let renderScaleItem = NSUserInterfaceItemIdentifier("avo.graphics.renderScale")
    static let resolutionItem = NSUserInterfaceItemIdentifier("avo.graphics.resolution")
    static let aspectRatioItem = NSUserInterfaceItemIdentifier("avo.graphics.aspectRatio")
    static let phoneRatioItem = NSUserInterfaceItemIdentifier("avo.graphics.phoneRatio")

    /// Appends the graphics items to the View menu and becomes its delegate.
    func addItems(to menu: NSMenu) {
        menu.delegate = self
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let profile = menu.addItem(withTitle: String(localized: "Preset: Apps", bundle: .windowHost), action: nil, keyEquivalent: "")
        profile.identifier = Self.profileLine
        profile.isEnabled = false
        menu.addItem(withTitle: String(localized: "Use the Games Preset", bundle: .windowHost),
                     action: #selector(AndroidWindowController.toggleGameSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // How Android's screen is sized, one of three (the window checks one).
        let modes: [(GraphicsSettings.Mode, String)] = [
            (.followWindow, String(localized: "Screen Size: Window", bundle: .windowHost)),
            (.fixed, String(localized: "Screen Size: Fixed", bundle: .windowHost)),
            (.deviceProfile, String(localized: "Screen Size: Phone", bundle: .windowHost)),
        ]
        for (mode, title) in modes {
            menu.addItem(withTitle: title, action: #selector(AndroidWindowController.chooseResolutionMode(_:)), keyEquivalent: "")
                .representedObject = mode.rawValue
        }

        let scales = NSMenu(title: String(localized: "Render Scale", bundle: .windowHost))
        for preset in GraphicsSettings.RenderScalePreset.allCases {
            scales.addItem(withTitle: Self.title(preset), action: #selector(AndroidWindowController.chooseRenderScale(_:)), keyEquivalent: "")
                .tag = preset.rawValue
        }
        submenu(scales, in: menu, id: Self.renderScaleItem)

        let resolutions = NSMenu(title: String(localized: "Resolution", bundle: .windowHost))
        for pixels in GraphicsSettings.resolutionPresets {
            resolutions.addItem(withTitle: GraphicsSettings.resolutionName(pixels), action: #selector(AndroidWindowController.chooseResolution(_:)), keyEquivalent: "")
                .tag = pixels
        }
        resolutions.addItem(withTitle: String(localized: "Custom…", bundle: .windowHost),
                            action: #selector(AndroidWindowController.chooseResolution(_:)), keyEquivalent: "").tag = 0
        submenu(resolutions, in: menu, id: Self.resolutionItem)

        let ratios = NSMenu(title: String(localized: "Aspect Ratio", bundle: .windowHost))
        for ratio in GraphicsSettings.AspectRatio.allCases {
            let title = ratio == .matchWindow ? String(localized: "Match Window", bundle: .windowHost) : ratio.rawValue
            ratios.addItem(withTitle: title, action: #selector(AndroidWindowController.chooseAspectRatio(_:)), keyEquivalent: "")
                .representedObject = ratio.rawValue
        }
        submenu(ratios, in: menu, id: Self.aspectRatioItem)
        // In the phone's mode: its shape, which nothing here changes.
        let phoneRatio = menu.addItem(withTitle: String(localized: "Aspect Ratio", bundle: .windowHost), action: nil, keyEquivalent: "")
        phoneRatio.identifier = Self.phoneRatioItem
        phoneRatio.isEnabled = false

        let orientations = NSMenu(title: String(localized: "Orientation", bundle: .windowHost))
        for orientation in VMConfig.Orientation.allCases {
            let title = orientation == .portrait ? String(localized: "Portrait", bundle: .windowHost) : String(localized: "Landscape", bundle: .windowHost)
            orientations.addItem(withTitle: title, action: #selector(AndroidWindowController.chooseOrientation(_:)), keyEquivalent: "")
                .representedObject = orientation.rawValue
        }
        submenu(orientations, in: menu, id: nil)

        let filters = NSMenu(title: String(localized: "Upscaling", bundle: .windowHost))
        for filter in GraphicsSettings.Filter.allCases {
            let title = switch filter {
            case .metalFXSpatial: String(localized: "Sharp (MetalFX)", bundle: .windowHost)
            case .bilinear: String(localized: "Smooth", bundle: .windowHost)
            case .nearest: String(localized: "Pixel Art", bundle: .windowHost)
            }
            filters.addItem(withTitle: title, action: #selector(AndroidWindowController.chooseScalingFilter(_:)), keyEquivalent: "")
                .representedObject = filter.rawValue
        }
        submenu(filters, in: menu, id: nil)

        let smoothing = NSMenu(title: String(localized: "Smooth Edges", bundle: .windowHost))
        for value in GraphicsSettings.AntiAliasing.allCases {
            smoothing.addItem(withTitle: Self.title(value), action: #selector(AndroidWindowController.chooseAntiAliasing(_:)), keyEquivalent: "")
                .representedObject = value.rawValue
        }
        submenu(smoothing, in: menu, id: nil)

        menu.addItem(.separator())
        // ⌥⌘ and ⌃⌘ combinations never reach Android (MacShortcuts), so the menu gets them.
        menu.addItem(withTitle: String(localized: "Show Performance HUD", bundle: .windowHost),
                     action: #selector(AndroidWindowController.togglePerformanceHUD(_:)), keyEquivalent: "p")
            .keyEquivalentModifierMask = [.command, .option]
        let levels = NSMenu(title: String(localized: "Performance HUD", bundle: .windowHost))
        for level in [PerformanceHUDLevel.fps, .detailed] {
            let title = level == .fps ? String(localized: "FPS Only", bundle: .windowHost) : String(localized: "Detailed", bundle: .windowHost)
            levels.addItem(withTitle: title, action: #selector(AndroidWindowController.choosePerformanceHUDLevel(_:)), keyEquivalent: "")
                .representedObject = level.rawValue
        }
        submenu(levels, in: menu, id: nil)
        // This app's windows in the Phone app bar style (also Device › Phone Style in its windows).
        menu.addItem(withTitle: String(localized: "Phone Style", bundle: .windowHost),
                     action: #selector(AndroidWindowController.togglePhoneStyle(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Use Default Graphics Settings", bundle: .windowHost),
                     action: #selector(AndroidWindowController.useDefaultGraphicsSettings(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        // AppKit retitles it Exit Full Screen while in full screen.
        menu.addItem(withTitle: String(localized: "Enter Full Screen", bundle: .windowHost),
                     action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
            .keyEquivalentModifierMask = [.command, .control]
    }

    private func submenu(_ submenu: NSMenu, in menu: NSMenu, id: NSUserInterfaceItemIdentifier?) {
        let item = menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.identifier = id
    }

    static func title(_ value: GraphicsSettings.AntiAliasing) -> String {
        switch value {
        case .off: String(localized: "Off", bundle: .windowHost)
        case .fxaa: String(localized: "Fast (FXAA)", bundle: .windowHost)
        case .ssaa2x: String(localized: "High (2× Supersampling)", bundle: .windowHost)
        case .ssaa4x: String(localized: "Ultra (4× Supersampling)", bundle: .windowHost)
        }
    }

    /// For a segmented control: "High".
    static func shortTitle(_ value: GraphicsSettings.AntiAliasing) -> String {
        switch value {
        case .off: String(localized: "Off", bundle: .windowHost)
        case .fxaa: String(localized: "Fast", bundle: .windowHost)
        case .ssaa2x: String(localized: "High", bundle: .windowHost)
        case .ssaa4x: String(localized: "Ultra", bundle: .windowHost)
        }
    }

    static func title(_ preset: GraphicsSettings.RenderScalePreset) -> String {
        let percent = preset.rawValue
        return switch preset {
        case .native: String(localized: "Native (\(percent)%)", bundle: .windowHost)
        case .ultraQuality: String(localized: "Ultra Quality (\(percent)%)", bundle: .windowHost)
        case .quality: String(localized: "Quality (\(percent)%)", bundle: .windowHost)
        case .balanced: String(localized: "Balanced (\(percent)%)", bundle: .windowHost)
        case .performance: String(localized: "Performance (\(percent)%)", bundle: .windowHost)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let window = NSApp.mainWindow ?? NSApp.keyWindow
        let controller = window?.windowController as? AndroidWindowController
        let mode = controller?.graphicsMenuMode
        for item in menu.items {
            switch item.identifier {
            case Self.profileLine?:
                item.title = mode?.profileLine ?? String(localized: "Preset: Apps", bundle: .windowHost)
            case Self.renderScaleItem?:
                item.isHidden = mode.map { $0.mode != .followWindow } ?? false
            case Self.resolutionItem?:
                item.isHidden = mode.map { $0.mode != .fixed } ?? true
            case Self.aspectRatioItem?:
                item.isHidden = mode?.mode == .deviceProfile
            case Self.phoneRatioItem?:
                item.isHidden = mode?.mode != .deviceProfile
                item.title = String(localized: "Aspect Ratio: \(mode?.phoneRatio ?? "") (the Phone’s)", bundle: .windowHost)
            default:
                break
            }
        }
    }
}
