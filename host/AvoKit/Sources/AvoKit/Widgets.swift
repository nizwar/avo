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
    /// Android shows its settings before it is added.
    public var configurable: Bool
    /// PNG: its preview, or the app's icon when it has none.
    public var preview: Data?

    public var id: String { provider }

    public init(provider: String, package: String, label: String, appLabel: String, minWidth: Int, minHeight: Int,
                cellWidth: Int = 0, cellHeight: Int = 0, resizable: Bool = false, configurable: Bool = false, preview: Data? = nil) {
        self.provider = provider
        self.package = package
        self.label = label
        self.appLabel = appLabel
        self.minWidth = minWidth
        self.minHeight = minHeight
        self.cellWidth = cellWidth
        self.cellHeight = cellHeight
        self.resizable = resizable
        self.configurable = configurable
        self.preview = preview
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

    public init(id: String = UUID().uuidString.lowercased(), provider: WidgetProvider) {
        self.id = id
        self.provider = provider.provider
        self.package = provider.package
        self.label = provider.label
        self.appLabel = provider.appLabel
        (width, height) = provider.defaultSize
        configurable = provider.configurable
    }
}
