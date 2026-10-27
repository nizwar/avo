import AppKit
import AvoKit
import Combine
import SwiftUI

// Whether macOS shows Android notifications in Notification Center: the
// Notifications pane's banner and Settings › System › Notifications. The
// daemon posts them, so it is the process that asks macOS (Request
// Permission). System Settings tells nobody when the user changes Avo's
// notifications there, so these views ask the daemon again every few
// seconds while they show and when Avo comes back to the front.

/// Above the Notifications pane's list while macOS does not show them.
struct MacNotificationsBanner: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        if model.daemonState == .connected, let permission = model.macNotifications, !permission.isAllowed {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge.slash").foregroundStyle(.orange).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    if permission.state == .unavailable {
                        Text("macOS can’t show Avo’s notifications").font(.headline)
                    } else {
                        Text("macOS notifications are off for Avo").font(.headline)
                    }
                    BannerExplanation(permission: permission)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                PermissionButton(permission: permission)
            }
            .padding(12)
            .background(.orange.opacity(0.12))
            .help(permission.temporaryFolder.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
        }
    }
}

private struct BannerExplanation: View {
    let permission: MacNotificationPermission

    var body: some View {
        switch permission.state {
        case .notDetermined where permission.asking:
            Text("macOS is asking now: choose Allow in its notification at the top right of the screen.")
        case .notDetermined, .allowed:
            Text("Android notifications only appear in this list. Request permission to see them in Notification Center as well.")
        case .denied:
            Text("Android notifications only appear in this list. Turn on Allow Notifications for Avo to see them in Notification Center.")
        case .unavailable:
            UnavailableExplanation(permission: permission)
        }
    }
}

/// Settings › System: the same permission, also once it is on.
struct MacNotificationsSection: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        Section("Notifications") {
            LabeledContent {
                if let permission = model.macNotifications {
                    PermissionButton(permission: permission)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HelpTitle("Show in Notification Center",
                              help: "Android notifications always appear in Avo’s Notifications list. Once macOS allows Avo, they appear in Notification Center too, grouped by app; clicking one opens its app.")
                    if let permission = model.macNotifications {
                        SettingsStatus(permission: permission)
                            .font(.mona(12))
                            .foregroundStyle(permission.isAllowed ? Haze.textTertiary : Haze.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .refreshesMacNotifications()
            if let config = model.config {
                Toggle(isOn: Binding(get: { config.dockBadges }, set: { value in model.update { $0.dockBadges = value } })) {
                    HelpTitle("Badges in the Dock",
                              help: "An open app’s Dock icon shows how many notifications it has in Android, as a phone’s home screen does.")
                }
            }
        }
    }
}

private struct SettingsStatus: View {
    let permission: MacNotificationPermission

    var body: some View {
        switch permission.state {
        case .allowed:
            Text("On")
        case .notDetermined where permission.asking:
            Text("macOS is asking now: choose Allow in its notification at the top right of the screen.")
        case .notDetermined:
            Text("Off until you allow it. macOS asks once.")
        case .denied:
            Text("Off. Turn on Allow Notifications for Avo in System Settings; macOS doesn’t ask again.")
        case .unavailable:
            UnavailableExplanation(permission: permission)
        }
    }
}

/// macOS refused to ask: an Avo.app in a temporary folder (a build run from
/// /tmp, or an app opened from Downloads without moving it) is one it does
/// not know.
private struct UnavailableExplanation: View {
    let permission: MacNotificationPermission

    var body: some View {
        if permission.temporaryFolder != nil {
            Text("Move Avo to the Applications folder to allow notifications.")
        } else {
            Text("macOS didn’t ask for permission: \(permission.refusal ?? "")")
        }
    }
}

/// Request Permission while macOS has no answer; once it has a "no", only
/// System Settings can change it.
private struct PermissionButton: View {
    @Environment(ControlPanelModel.self) private var model
    let permission: MacNotificationPermission

    var body: some View {
        HStack(spacing: 8) {
            if model.requestingNotificationPermission {
                ProgressView().controlSize(.small)
            }
            switch permission.state {
            case .notDetermined:
                Button("Request Permission") { model.requestNotificationPermission() }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 30, fontSize: 12.5, horizontalPadding: 14))
                    .disabled(model.requestingNotificationPermission)
                    .help("macOS asks once, in a notification at the top right of the screen. Choose Allow there.")
            case .denied:
                Button("Open Notification Settings") { model.openNotificationSettings() }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 30, fontSize: 12.5, horizontalPadding: 14))
            case .unavailable:
                Button("Try Again") { model.requestNotificationPermission() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12.5, horizontalPadding: 14))
                    .disabled(model.requestingNotificationPermission)
            case .allowed:
                Button("Open Notification Settings") { model.openNotificationSettings() }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12.5, horizontalPadding: 14))
            }
        }
        .fixedSize()
    }
}

/// Asks the daemon again every few seconds while the view shows, and when Avo
/// comes back to the front (from System Settings, say).
private struct RefreshesMacNotifications: ViewModifier {
    @Environment(ControlPanelModel.self) private var model

    func body(content: Content) -> some View {
        content
            .task {
                while !Task.isCancelled {
                    // Only while a window of Avo shows (not minimized or covered).
                    if NSApp.occlusionState.contains(.visible) { await model.refreshNotificationPermission() }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await model.refreshNotificationPermission() }
            }
    }
}

extension View {
    func refreshesMacNotifications() -> some View {
        modifier(RefreshesMacNotifications())
    }
}
