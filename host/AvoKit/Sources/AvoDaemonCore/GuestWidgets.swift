import AvoKit
import CryptoKit
import Foundation

/// Avo Widgets in Android (guest/widgets): the widgets Android's apps offer,
/// and letting go of a removed panel's widget. HostAgent installs it.
protocol WidgetsGuest: Sendable {
    func widgetProviders() async throws -> [WidgetProvider]
    /// Android lets go of the widget a removed panel showed.
    func deleteWidget(slot: String) async
}

/// An engine whose Android shows widgets (VMMEngine, through HostAgent).
protocol WidgetsEngine: VMEngine {
    /// Android's shell once Android is ready; throws `AvoError.vmNotRunning` before.
    func widgetsGuest() async throws -> any WidgetsGuest
}

enum GuestWidgets {
    static let listCommand = "content read --uri content://\(AndroidWidgets.package)/providers"

    static func deleteCommand(slot: String) -> String {
        "content call --uri content://\(AndroidWidgets.package) --method delete --arg " + HostAgent.quote(slot)
    }

    /// Lets Avo Widgets bind any app's widget without asking (as a launcher may).
    static let grantCommand = "appwidget grantbind --package \(AndroidWidgets.package) --user 0"

    /// `content read`'s output: Avo Widgets' JSON array, sorted by app and widget.
    static func providers(_ output: String) throws -> [WidgetProvider] {
        guard let start = output.firstIndex(of: "[") else {
            throw AvoError.internalError("Avo Widgets did not answer: \(output.prefix(200))")
        }
        let list = try JSONDecoder().decode([WidgetProvider].self, from: Data(output[start...].utf8))
        return list.sorted {
            ($0.appLabel.localizedLowercase, $0.label.localizedLowercase) < ($1.appLabel.localizedLowercase, $1.label.localizedLowercase)
        }
    }

    /// The `am start` that shows a panel's widget on its display: a task of
    /// its own (NEW_TASK | MULTIPLE_TASK), one per panel.
    static func startCommand(data: String, display: Int) -> String {
        "am start --display \(display) -f 0x18000000 -n \(AndroidWidgets.activity) -d " + HostAgent.quote(data)
    }
}

extension HostAgent {
    /// This build's Avo Widgets (WidgetsHelper, from guest/widgets/build.sh)
    /// and its SHA-256 as `sha256sum` prints it.
    static let widgetsAPK: (data: Data, sha256: String)? = Data(base64Encoded: WidgetsHelper.apk).map { data in
        (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
