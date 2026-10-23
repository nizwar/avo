import Foundation

// Android widgets on the Mac (Library › Widgets). Avo Widgets, an app Avo
// installs in Android (guest/widgets), shows each widget on a display of
// its own, and a floating panel on the Mac shows that display, live: the
// widget updates and takes clicks as on a phone's home screen. The daemon
// keeps the panels (`widgets.json`) and the panels themselves run in it
// (AvoWindowHost's WidgetPanels).

public enum AndroidWidgets {
    /// Avo Widgets' package: its displays are the widget panels'.
    public static let package = "\(AvoIdentifiers.prefix).widgets"
    /// The package of the builds before 0.3.0 Preview 2, uninstalled once
    /// this one is in (its widgets come back in this one's panels by themselves).
    public static let formerPackage = "\(AvoIdentifiers.formerPrefix).widgets"
    /// The activity that shows one widget on its display.
    public static let activity = "\(package)/.WidgetActivity"

    /// The data the activity starts with: the panel's slot and the widget's provider.
    public static func launchURI(slot: String, provider: String) -> String {
        var components = URLComponents()
        components.scheme = "avo-widget"
        components.host = slot
        components.queryItems = [URLQueryItem(name: "provider", value: provider)]
        return components.string ?? "avo-widget://\(slot)"
    }

    /// A panel's size in points (= Android's dp) stays in these bounds.
    public static let sizeRange = 48...720
    /// How far a widget that keeps its layout zooms (points per dp).
    public static let zoomRange = 0.5...2.5
    /// A panel's size while Android shows the widget's settings.
    public static let setupSize = (width: 360, height: 600)

    /// The display's top activity is Avo Widgets' (the widget), not the widget's settings.
    public static func showsWidget(top: String) -> Bool { top.hasPrefix(package + "/") }
}

/// A widget an Android app offers (Android's AppWidgetProviderInfo).
public struct WidgetProvider: Codable, Equatable, Sendable, Identifiable {
    /// `package/class` of its AppWidgetProvider.
    public var provider: String
    public var package: String
    public var label: String
    /// The app's name.
    public var appLabel: String
    /// The smallest size it asks for, in dp.
    public var minWidth: Int
    public var minHeight: Int
    /// The launcher cells it would like (0: it does not say).
    public var cellWidth: Int
    public var cellHeight: Int
    public var resizable: Bool
    /// How it resizes; nil from an Avo Widgets that said only `resizable`.
    public var resizing: WidgetResizing?
    /// Android shows its settings before it is added.
    public var configurable: Bool
    /// PNG: its preview, or the app's icon when it has none.
    public var preview: Data?

    public var id: String { provider }

    public init(provider: String, package: String, label: String, appLabel: String, minWidth: Int, minHeight: Int,
                cellWidth: Int = 0, cellHeight: Int = 0, resizable: Bool = false, resizing: WidgetResizing? = nil,
                configurable: Bool = false, preview: Data? = nil) {
        self.provider = provider
        self.package = package
        self.label = label
        self.appLabel = appLabel
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.resizable = resizable
        self.resizing = resizing
        self.configurable = configurable
        self.preview = preview
    }

    /// How it resizes; without `resizing`, a resizable widget lays out down
    /// to its minimum size (Android's default for `minResizeWidth`).
    public var resizeRules: WidgetResizing {
        resizing ?? (resizable ? WidgetResizing(horizontal: true, vertical: true, minWidth: minWidth, minHeight: minHeight) : .fixed)
    }

    /// A launcher cell, in dp, as a phone's home screen (a 4 × 5 grid) has it.
    static let cell = (width: 80, height: 100)

    /// The size a new panel has, in points: whole launcher cells, as many as
    /// the widget wants or its minimum takes (Android's 73n − 16 rule), as a
    /// phone's home screen gives it. Widgets often draw past their minimum;
    /// what the widget leaves empty is transparent.
    public var defaultSize: (width: Int, height: Int) {
        func side(_ min: Int, _ cells: Int, _ cell: Int) -> Int {
            let count = cells > 0 ? cells : Swift.max(1, (min + 16 + 72) / 73)
            let range = AndroidWidgets.sizeRange
            return Swift.min(Swift.max(Swift.max(min, count * cell), range.lowerBound), range.upperBound)
        }
        return (side(minWidth, cellWidth, Self.cell.width), side(minHeight, cellHeight, Self.cell.height))
    }
}

/// A widget on the Mac: one floating panel.
public struct PlacedWidget: Codable, Equatable, Sendable, Identifiable {
    /// The panel's own name; Avo Widgets keeps its Android widget id under it.
    public var id: String
    public var provider: String
    public var package: String
    public var label: String
    public var appLabel: String
    /// The panel's size in points (= dp in Android).
    public var width: Int
    public var height: Int
    /// Android shows the widget's settings when it is first added (the
    /// panel is larger while it does). nil in lists saved before.
    public var configurable: Bool?
    /// How the widget resizes. nil in lists saved before: the daemon asks
    /// Android once it runs.
    public var resizing: WidgetResizing?

    public init(id: String = UUID().uuidString.lowercased(), provider: WidgetProvider) {
        self.id = id
        self.provider = provider.provider
        self.package = provider.package
        self.label = provider.label
        self.appLabel = provider.appLabel
        (width, height) = provider.defaultSize
        configurable = provider.configurable
        resizing = provider.resizeRules
    }

    /// The widget keeps its layout at any panel size: the panel zooms it
    /// instead of Android laying it out again. Not while its rules are unknown.
    public var zooms: Bool { resizing.map { !$0.resizes } ?? false }

    /// The panel sizes (points) the widget allows: its resize limits along
    /// the ways it resizes and its own size along the others, or a zoom of
    /// its own size; any size while its rules are unknown.
    public var panelSizeLimits: (min: CGSize, max: CGSize) {
        let range = AndroidWidgets.sizeRange
        let (lower, upper) = (CGFloat(range.lowerBound), CGFloat(range.upperBound))
        guard let resizing else { return (CGSize(width: lower, height: lower), CGSize(width: upper, height: upper)) }
        let own = CGSize(width: CGFloat(width), height: CGFloat(height))
        if !resizing.resizes {
            // No side under the smallest panel.
            let least = max(AndroidWidgets.zoomRange.lowerBound, lower / max(min(own.width, own.height), 1))
            let most = max(AndroidWidgets.zoomRange.upperBound, least)
            return (CGSize(width: own.width * least, height: own.height * least),
                    CGSize(width: own.width * most, height: own.height * most))
        }
        func side(_ resizes: Bool, _ own: CGFloat, _ least: Int, _ most: Int) -> (min: CGFloat, max: CGFloat) {
            guard resizes else { return (own, own) }
            let low = min(max(CGFloat(least), lower), upper)
            return (low, most > 0 ? min(max(CGFloat(most), low), upper) : upper)
        }
        let across = side(resizing.horizontal, own.width, resizing.minWidth, resizing.maxWidth)
        let down = side(resizing.vertical, own.height, resizing.minHeight, resizing.maxHeight)
        return (CGSize(width: across.min, height: down.min), CGSize(width: across.max, height: down.max))
    }

    /// The panel size (points) nearest `size` that the widget allows; a
    /// zooming widget's in its own shape, as wide as `size` allows.
    public func allowedPanelSize(_ size: CGSize) -> CGSize {
        let (low, high) = panelSizeLimits
        let width = min(max(size.width, low.width), high.width)
        if zooms { return CGSize(width: width, height: width * CGFloat(height) / CGFloat(max(self.width, 1))) }
        return CGSize(width: width, height: min(max(size.height, low.height), high.height))
    }

    /// Points per dp in a panel `width` points wide: 1 unless the widget zooms.
    public func zoom(panelWidth: CGFloat) -> CGFloat {
        zooms ? panelWidth / CGFloat(max(width, 1)) : 1
    }
}

/// How a widget resizes, as its app says (Android's `resizeMode` and resize
/// limits), in dp.
public struct WidgetResizing: Codable, Equatable, Sendable {
    public var horizontal: Bool
    public var vertical: Bool
    /// The smallest size it lays out for.
    public var minWidth: Int
    public var minHeight: Int
    /// The largest (0: it sets no limit).
    public var maxWidth: Int
    public var maxHeight: Int

    public init(horizontal: Bool, vertical: Bool, minWidth: Int = 0, minHeight: Int = 0, maxWidth: Int = 0, maxHeight: Int = 0) {
        self.horizontal = horizontal
        self.vertical = vertical
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    /// Neither way: the widget has one layout.
    public static let fixed = WidgetResizing(horizontal: false, vertical: false)

    public var resizes: Bool { horizontal || vertical }
}
