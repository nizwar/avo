import AppKit
import AVFoundation
import AvoKit
import SwiftUI

// The Setup Assistant's Permissions step: what Avo asks macOS for, and why.
//
// - Notifications: the daemon posts them, so the daemon asks
//   (`ControlPanelModel.requestNotificationPermission`, MacNotificationsViews.swift).
// - Microphone: macOS holds Avo.app responsible for the daemon and the engine
//   that records (see Avo/Info.plist), so asking here covers them.
// - Location: CoreLocation asks for the daemon itself, the first time an
//   Android app wants a GPS fix while sharing is on.

/// The microphone permission of Avo.app (which the engine records under).
@MainActor
@Observable
final class MicrophoneAccess {
    enum State: Equatable {
        case notAsked, allowed, denied, restricted
    }

    private(set) var state: State = MicrophoneAccess.current
    private(set) var asking = false

    static var current: State {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        default: .notAsked
        }
    }

    func refresh() { state = Self.current }

    /// macOS shows its alert once; afterwards only System Settings changes the answer.
    func request() {
        guard !asking else { return }
        asking = true
        Task {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            asking = false
            refresh()
        }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}

enum LocationSettings {
    static func open() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }
}

/// Notifications, microphone and location, each with what it is for and its
/// state or button, in one card.
struct SetupPermissionsList: View {
    @Environment(ControlPanelModel.self) private var model
    @State private var microphone = MicrophoneAccess()

    var body: some View {
        VStack(spacing: 0) {
            PermissionRow(symbol: "bell", tint: 0xEAA970, tintAlpha: 0.16, title: "Notifications",
                          purpose: "Android apps’ notifications appear in Notification Center, and clicking one opens its app.") {
                notificationStatus
            } action: {
                notificationButton
            }
            RowDivider()
            PermissionRow(symbol: "mic", tint: 0xD8E8A7, tintAlpha: 0.14, title: "Microphone",
                          purpose: "Apps that record, like voice notes and calls, hear this Mac’s microphone, only while they record.") {
                microphoneStatus
            } action: {
                microphoneButton
            }
            RowDivider()
            PermissionRow(symbol: "location", tint: 0xA9CFEE, tintAlpha: 0.14, title: "Location",
                          purpose: "Apps that ask for GPS get this Mac’s location. macOS asks the first time an app needs it.") {
                EmptyView()
            } action: {
                locationControl
            }
        }
        .background(Haze.tile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Haze.text.opacity(0.06)) }
        // An answer from macOS swaps a row's button for its badge smoothly.
        .animation(Haze.Motion.content, value: model.macNotifications?.state)
        .animation(Haze.Motion.content, value: microphone.state)
        .refreshesMacNotifications()
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in microphone.refresh() }
    }

    // MARK: Notifications (the daemon asks)

    @ViewBuilder private var notificationStatus: some View {
        switch model.macNotifications?.state {
        case .denied?: StatusLabel(text: "Off in System Settings", symbol: "xmark.circle.fill", tint: Haze.textTertiary)
        case .notDetermined? where model.macNotifications?.asking == true:
            StatusLabel(text: "macOS is asking now: choose Allow in its notification.", symbol: "hourglass", tint: Haze.warning)
        case .unavailable?: StatusLabel(text: "macOS can’t show Avo’s notifications from this copy of Avo.", symbol: "exclamationmark.triangle.fill", tint: Haze.warning)
        case nil: StatusLabel(text: "Available once Avo’s background service runs.", symbol: "hourglass", tint: Haze.textTertiary)
        case .allowed?, .notDetermined?: EmptyView()
        }
    }

    @ViewBuilder private var notificationButton: some View {
        switch model.macNotifications?.state {
        case .allowed?:
            AllowedBadge { model.openNotificationSettings() }
        case .notDetermined?:
            Button("Allow…") { model.requestNotificationPermission() }
                .buttonStyle(PermissionButtonStyle())
                .disabled(model.requestingNotificationPermission)
                .help("macOS asks once, in a notification at the top right of the screen. Choose Allow there.")
        case .denied?:
            Button("Settings…") { model.openNotificationSettings() }
                .buttonStyle(PermissionButtonStyle())
        case .unavailable?:
            Button("Try Again") { model.requestNotificationPermission() }
                .buttonStyle(PermissionButtonStyle())
                .disabled(model.requestingNotificationPermission)
        case nil:
            Button("Allow…") {}
                .buttonStyle(PermissionButtonStyle())
                .disabled(true)
        }
    }

    // MARK: Microphone (asked here)

    @ViewBuilder private var microphoneStatus: some View {
        switch microphone.state {
        case .denied: StatusLabel(text: "Off in System Settings", symbol: "xmark.circle.fill", tint: Haze.textTertiary)
        case .restricted: StatusLabel(text: "Not allowed on this Mac", symbol: "lock.fill", tint: Haze.textTertiary)
        case .notAsked, .allowed: EmptyView()
        }
    }

    @ViewBuilder private var microphoneButton: some View {
        switch microphone.state {
        case .notAsked:
            Button("Allow…") { microphone.request() }
                .buttonStyle(PermissionButtonStyle())
                .disabled(microphone.asking)
        case .allowed:
            AllowedBadge { MicrophoneAccess.openSettings() }
        case .denied, .restricted:
            Button("Settings…") { MicrophoneAccess.openSettings() }
                .buttonStyle(PermissionButtonStyle())
        }
    }

    // MARK: Location (the daemon asks when it is needed)

    @ViewBuilder private var locationControl: some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { model.config?.shareLocation ?? true },
                                 set: { value in model.update { $0.shareLocation = value } })) {
                Text("Share")
            }
            .toggleStyle(HazeSwitchStyle())
            .disabled(model.config == nil)
            .accessibilityLabel(Text("Share this Mac’s location with Android"))
            Button("Settings…") { LocationSettings.open() }
                .buttonStyle(HazeLinkButtonStyle())
                .font(.mona(13))
                .foregroundStyle(Haze.textSecondary)
                .padding(.horizontal, 12)
                .frame(height: 36)
        }
    }
}

private struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Haze.text.opacity(0.06)).frame(height: 1).padding(.horizontal, 18)
    }
}

private struct PermissionRow<Status: View, Action: View>: View {
    let symbol: String
    let tint: UInt32
    let tintAlpha: Double
    let title: LocalizedStringKey
    let purpose: LocalizedStringKey
    @ViewBuilder var status: Status
    @ViewBuilder var action: Action

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Haze.tint(tint))
                .frame(width: 40, height: 40)
                .background(Haze.tint(tint, alpha: tintAlpha), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.mona(14.5, 600))
                Text(purpose)
                    .font(.mona(12.5))
                    .hazeParagraph(1.45, size: 12.5)
                    .foregroundStyle(Haze.purpose)
                    .fixedSize(horizontal: false, vertical: true)
                status.font(.mona(12))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action
                .fixedSize()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .accessibilityElement(children: .contain)
    }
}

/// "Allowed" with a check; clicking it opens the setting in System Settings.
private struct AllowedBadge: View {
    let openSettings: () -> Void

    var body: some View {
        Button(action: openSettings) {
            // The check draws itself as permission arrives.
            HStack(spacing: 6) {
                HazeCheck(color: Haze.accent, lineWidth: 1.9, drawsOnAppear: true)
                    .frame(width: 10, height: 9)
                Text("Allowed")
            }
            .font(.mona(12.5, 600))
            .foregroundStyle(Haze.accent)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(Haze.selection, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(HazeLinkButtonStyle())
        .help("Open System Settings")
        .transition(.opacity.combined(with: .scale(scale: 0.85)))
    }
}

private struct PermissionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PermissionButtonBody(configuration: configuration)
    }
}

private struct PermissionButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .font(.mona(13, 600))
            .foregroundStyle(Haze.text)
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Haze.text.opacity(pressed ? 0.16 : hovering && isEnabled ? 0.14 : 0.10), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? Haze.Motion.pressScale : 1)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(Haze.Motion.press, value: pressed)
            .animation(Haze.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// The design's switch: moss green and glowing when on. The knob springs
/// across, with a light tick on the trackpad.
struct HazeSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion)) { configuration.isOn.toggle() }
            Haze.Haptics.snap()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Haze.moss : Haze.text.opacity(0.16))
                    .shadow(color: configuration.isOn ? Haze.accent.opacity(0.35) : .clear, radius: 7)
                Circle()
                    .fill(Haze.knob)
                    .shadow(color: Haze.shadow.opacity(0.45), radius: 1.5, y: 1)
                    .frame(width: 20, height: 20)
                    .padding(3)
            }
            .frame(width: 44, height: 26)
            // Also when the setting changes from elsewhere.
            .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: configuration.isOn)
        }
        .buttonStyle(HazeCardButtonStyle())
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityValue(configuration.isOn ? Text("On") : Text("Off"))
    }
}

struct StatusLabel: View {
    let text: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).foregroundStyle(Haze.purpose)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
    }
}
