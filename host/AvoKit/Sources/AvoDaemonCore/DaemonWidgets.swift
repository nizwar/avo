import AvoKit
import Foundation
import os

// MARK: - Widgets (Library › Widgets)

/// Android widgets on the Mac. The daemon keeps the list (`widgets.json`);
/// the panels that show them run in the daemon's process as a client of
/// their own (`registerInProcess`, role `shim(AndroidWidgets.package)`):
/// each opens a display on which Avo Widgets shows its widget.
extension DaemonCore {
    static func loadWidgets(_ paths: AvoPaths) -> [PlacedWidget] {
        guard let data = try? Data(contentsOf: paths.widgets) else { return [] }
        return (try? JSONDecoder().decode([PlacedWidget].self, from: data)) ?? []
    }

    private func saveWidgets() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(placedWidgets).write(to: deps.paths.widgets, options: .atomic)
        } catch {
            Logger(subsystem: AvoIdentifiers.logSubsystem, category: "Widgets")
                .error("cannot save widgets: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func hearsWidgets(_ role: ClientHello.Role) -> Bool {
        role == .controlPanel || role == .shim(package: AndroidWidgets.package)
    }

    private func widgetsChanged() {
        saveWidgets()
        broadcast(.widgets(placedWidgets), to: Self.hearsWidgets)
    }

    private func widgetsGuest() async throws -> any WidgetsGuest {
        guard let engine = deps.engine as? any WidgetsEngine else {
            throw AvoError.internalError(String(localized: "This Android shows no widgets.", bundle: .avoKit))
        }
        return try await engine.widgetsGuest()
    }

    /// The widgets Android's apps offer; Android has to be running.
    public func widgetProviders(client: ClientID) async throws -> [WidgetProvider] {
        try requireControlPanel(client)
        return try await widgetsGuest().widgetProviders()
    }

    public func placedWidgets(client: ClientID) async throws -> [PlacedWidget] {
        try requireControlPanel(client)
        return placedWidgets
    }

    /// A new panel for `provider`'s widget; Android binds it when the panel opens.
    public func addWidget(_ provider: String, client: ClientID) async throws -> PlacedWidget {
        try requireControlPanel(client)
        guard let info = try await widgetsGuest().widgetProviders().first(where: { $0.provider == provider }) else {
            throw AvoError.internalError(String(localized: "Android no longer has this widget.", bundle: .avoKit))
        }
        let widget = PlacedWidget(provider: info)
        placedWidgets.append(widget)
        widgetsChanged()
        return widget
    }

    /// Removed in the Library or with its panel's close button: Android lets go of it too.
    public func removeWidget(_ id: String, client: ClientID) async throws {
        guard let role = role(of: client), Self.hearsWidgets(role) else { throw AvoError.unauthorizedCaller }
        guard placedWidgets.contains(where: { $0.id == id }) else { return }
        placedWidgets.removeAll { $0.id == id }
        widgetsChanged()
        await (try? widgetsGuest())?.deleteWidget(slot: id)
    }

    /// A client living in the daemon's own process (the widget panels):
    /// registered as an XPC client is, without a connection.
    public func registerInProcess(role: ClientHello.Role, proxy: ClientProxy) async -> ClientID {
        let id = ClientID()
        _ = await register(id, role: role, proxy: proxy)
        return id
    }
}
