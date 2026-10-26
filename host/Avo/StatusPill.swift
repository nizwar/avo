import AppKit
import AvoKit
import SwiftUI

/// Android's state and quick actions in a capsule that floats over the
/// Library window's bottom edge, half outside it. It lives in a child panel
/// of the window (StatusPillController), so it moves, hides and minimizes
/// with it; in full screen it sits just inside the bottom edge, and it never
/// goes under the Dock (a window zoomed to the screen keeps it above). The
/// window's content ends above it (`StatusPillRoom`), so it covers nothing. Between
/// states its words morph and the capsule eases to its new width; the dot
/// changes colour softly and breathes while Android starts or stops.
struct StatusPill: View {
    @Environment(ControlPanelModel.self) private var model
    /// The window it floats under (nil in offscreen renders).
    @Environment(StatusPillHost.self) private var host: StatusPillHost?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openSettings: () -> Void
    /// Offscreen renders draw the window shadow themselves.
    var drawsShadow = false

    var body: some View {
        let morph = Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion)
        HStack(spacing: 16) {
            RunningDot(size: 9, color: dotColor, pulsing: underWay && (host?.windowActive ?? false))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.mona(14, 600)).foregroundStyle(Haze.text).lineLimit(1)
                    .contentTransition(reduceMotion ? .opacity : .interpolate)
                if let subtitle {
                    Text(subtitle).font(.mona(12)).foregroundStyle(Haze.textTertiary).lineLimit(1)
                        .contentTransition(reduceMotion ? .opacity : .interpolate)
                        .transition(.opacity)
                }
            }
            .frame(minWidth: 220, alignment: .leading)
            actions
            Button("Settings", action: openSettings)
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 44, fontSize: 14, horizontalPadding: 18))
        }
        .padding(.leading, 22)
        .padding(.trailing, 10)
        .frame(height: 64)
        .animation(morph, value: title)
        .animation(morph, value: subtitle)
        .animation(morph, value: model.status.state)
        .background {
            ZStack {
                Capsule().fill(.ultraThinMaterial)
                Capsule().fill(Haze.pillFill)
                Capsule().strokeBorder(Haze.accent.opacity(0.18))
            }
        }
        .compositingGroup()
        .shadow(color: Haze.shadow.opacity(drawsShadow ? 0.55 : 0), radius: 25, y: 18)
        .shadow(color: Haze.accent.opacity(drawsShadow ? 0.12 : 0), radius: 30)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Android status"))
    }

    @ViewBuilder private var actions: some View {
        let state = model.status.state
        let connected = model.daemonState == .connected
        if state == .running {
            Button { model.stopVM() } label: { Image(systemName: "stop.fill").font(.system(size: 14)) }
                .buttonStyle(HazeIconButtonStyle())
                .disabled(model.googleAppsChangingAndroid)
                .help("Stop Android. Open apps close.")
                .accessibilityLabel(Text("Stop Android"))
                .transition(swap)
        } else {
            Button { model.startVM() } label: { Image(systemName: "play.fill").font(.system(size: 14)) }
                .buttonStyle(HazeIconButtonStyle())
                .disabled(state.isBusy || !connected || model.googleAppsChangingAndroid)
                // Starting a paused Android resumes it.
                .help(state == .suspended ? Text("Resume Android") : Text("Start Android in the background."))
                .accessibilityLabel(state == .suspended ? Text("Resume Android") : Text("Start Android"))
                .transition(swap)
        }
        Button { model.restartVM() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 15, weight: .semibold)) }
            .buttonStyle(HazeIconButtonStyle(fill: model.pendingRestart ? Haze.accent.opacity(0.22) : Haze.button))
            .disabled(state != .running || model.googleAppsChangingAndroid)
            .help(model.pendingRestart ? Text("Restart Android to apply your changes. Your apps and data are kept.") : Text("Restart Android"))
            .accessibilityLabel(Text("Restart Android"))
    }

    /// Play and Stop trade places.
    private var swap: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.7))
    }

    /// Android starting, stopping or saving its state.
    private var underWay: Bool {
        guard model.daemonState == .connected else { return false }
        switch model.status.state {
        case .starting, .stopping, .suspending: return true
        default: return false
        }
    }

    private var dotColor: Color {
        guard model.daemonState == .connected else { return Haze.textTertiary }
        switch model.status.state {
        case .running: return Haze.running
        case .starting, .stopping, .suspending: return Haze.warning
        case .failed: return Haze.danger
        default: return Haze.textTertiary
        }
    }

    /// "Android 17 is running".
    private var title: String {
        switch model.daemonState {
        case .connecting: return String(localized: "Connecting…")
        case .needsApproval, .unavailable: return String(localized: "Not connected")
        case .connected: break
        }
        let android = Self.shortVersion(model.status.androidVersion) ?? "Android"
        switch model.status.state {
        case .running: return String(localized: "\(android) is running")
        case .starting: return String(localized: "Android is starting…")
        case .stopping: return String(localized: "Android is stopping…")
        case .suspending: return String(localized: "Android is pausing…")
        case .suspended: return String(localized: "Android is paused")
        case .stopped: return String(localized: "Android is stopped")
        case .failed: return String(localized: "Android stopped with an error")
        case .notInstalled: return String(localized: "Android isn’t set up yet")
        }
    }

    /// "GPU · Apple M4 Pro · 8 GB memory", or what Android is doing.
    private var subtitle: String? {
        guard model.daemonState == .connected else { return nil }
        let status = model.status
        if status.isPaused {
            return status.pause?.automatic == true ? String(localized: "Paused to save energy. Opening an app resumes it.")
                                                   : String(localized: "Opening an app resumes it.")
        }
        guard status.state == .running else { return status.detail }
        var parts: [String] = []
        if let renderer = status.renderer {
            parts.append(renderer.mode == .gpu ? "GPU" : String(localized: "Software"))
            if renderer.mode == .gpu, let device = renderer.detail, !device.isEmpty { parts.append(device) }
        }
        if let config = model.config {
            let memory = config.androidMemoryMiB(profile: model.profiles.first { $0.id == config.deviceProfileID }, host: model.host)
            let gigabytes = (Double(memory) / 1024).formatted(.number.precision(.fractionLength(0...1)))
            parts.append(String(localized: "\(gigabytes) GB memory"))
        }
        if status.openDisplays > 0 { parts.append(String(localized: "\(status.openDisplays) open windows")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Android 17" from "Android 17 (API 37)".
    static func shortVersion(_ version: String?) -> String? {
        guard let version, !version.isEmpty else { return nil }
        return version.components(separatedBy: " (").first
    }
}

/// What the pill knows of the window it floats under.
@MainActor
@Observable
final class StatusPillHost {
    /// The window is key and on screen: the dot may breathe.
    var windowActive = false
}

/// The room the pill takes at the bottom of its window: how far it reaches
/// up into it, with a gap. The Library's content and an app's page end above
/// it, so the pill never covers a card or a row (the user, 2026-10-25:
/// "floating bar dibawah menutup content").
@MainActor
@Observable
final class StatusPillRoom {
    var bottom: CGFloat = 0
}

/// Keeps the status pill's panel under its Library window, always: centred
/// on the window's bottom edge, resized with its content, away while the
/// window is closed and back when SwiftUI shows the same window again.
/// While the capsule morphs to a new width the panel keeps room for its
/// widest moment (the rest of the panel is clear), and its shadow follows
/// the capsule frame by frame.
@MainActor
final class StatusPillController {
    private static var controllers: [ObjectIdentifier: StatusPillController] = [:]
    private weak var window: NSWindow?
    private let panel: NSPanel
    private let hosting: NSHostingView<AnyView>
    private var observers: [NSObjectProtocol] = []
    private let host = StatusPillHost()
    private weak var room: StatusPillRoom?
    /// The capsule's own size (SwiftUI's), zero before its first layout.
    private var contentSize = CGSize.zero
    /// Until then the capsule is easing to a new size.
    private var morphingUntil: CFTimeInterval = 0
    private let clock = HazeFrameClock()

    /// Between the pill's top and the content above it.
    static let roomGap: CGFloat = 12
    /// Between the Dock (or the screen's bottom) and the pill.
    static let dockGap: CGFloat = 16

    /// Puts the pill under `window`, once per window; `room` hears how much
    /// of the window's bottom it takes.
    static func attach(to window: NSWindow, model: ControlPanelModel, room: StatusPillRoom, openSettings: @escaping () -> Void) {
        // The pills of windows that are gone (one could share the new window's identifier).
        for (key, controller) in controllers where controller.window == nil {
            controller.detach()
            controllers[key] = nil
        }
        let key = ObjectIdentifier(window)
        if let existing = controllers[key] {
            existing.update()
            return
        }
        controllers[key] = StatusPillController(window: window, model: model, room: room, openSettings: openSettings)
    }

    private init(window: NSWindow, model: ControlPanelModel, room: StatusPillRoom, openSettings: @escaping () -> Void) {
        self.window = window
        self.room = room
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 64), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The shadow follows the capsule (the panel is clear around it).
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.fullScreenAuxiliary]
        hosting = NSHostingView(rootView: AnyView(EmptyView()))
        // The controller sizes the panel itself (from the capsule's size), so
        // the capsule can morph inside a panel that is briefly wider.
        hosting.sizingOptions = []
        panel.contentView = hosting
        let host = self.host
        hosting.rootView = AnyView(StatusPill(openSettings: openSettings)
            .environment(model)
            .environment(host)
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.contentResized(size)
            })
        // Its first layout reports the capsule's size (until then a guess sizes the panel).
        hosting.layoutSubtreeIfNeeded()
        clock.attach(to: panel)
        clock.onTick = { [weak self] now in self?.morphStep(now) }
        let center = NotificationCenter.default
        // Also whenever the window shows (it may not be on screen yet when the pill is attached).
        for name in [NSWindow.didResizeNotification, NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                     NSWindow.didChangeScreenNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didMiniaturizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            })
        }
        observers.append(center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowClosed() }
        })
        update()
    }

    /// The capsule grows and shrinks with its text, easing to its new size.
    private func contentResized(_ size: CGSize) {
        guard size != contentSize else { return }
        let first = contentSize == .zero
        contentSize = size
        if !first, panel.isVisible {
            morphingUntil = CACurrentMediaTime() + 0.6
            clock.isRunning = true
        }
        // After SwiftUI's layout pass (the capsule starts its morph at its old size).
        Task { @MainActor [weak self] in self?.update() }
    }

    /// While the capsule morphs, its shadow follows it; then the panel fits it again.
    private func morphStep(_ now: CFTimeInterval) {
        panel.invalidateShadow()
        guard now >= morphingUntil else { return }
        clock.isRunning = false
        update()
    }

    private func update() {
        guard let window else { return }
        var size = contentSize
        if size == .zero {
            let fitting = hosting.fittingSize
            size = fitting.width > 0 && fitting.height > 0 ? fitting : CGSize(width: 520, height: 64)
        }
        let frame = window.frame
        let fullScreen = window.styleMask.contains(.fullScreen)
        // Room for the capsule's widest moment while it morphs (the panel is clear around it).
        let morphing = CACurrentMediaTime() < morphingUntil && panel.isVisible
        let width = morphing ? max(size.width, panel.frame.width) : size.width
        let y = Self.pillY(windowFrame: frame, height: size.height, fullScreen: fullScreen, visibleFrame: window.screen?.visibleFrame)
        panel.setFrame(NSRect(x: (frame.midX - width / 2).rounded(), y: y.rounded(), width: width, height: size.height), display: true)
        panel.invalidateShadow()
        let bottom = Self.reach(pillY: y.rounded(), height: size.height, windowFrame: frame)
        if let room, room.bottom != bottom { room.bottom = bottom }
        let active = window.isKeyWindow && window.occlusionState.contains(.visible)
        if host.windowActive != active { host.windowActive = active }
        // Not on screen yet, or closed: the next show calls this again.
        guard window.isVisible else { return }
        if panel.parent == nil { window.addChildWindow(panel, ordered: .above) }
        fadeIn()
    }

    /// Where the pill's bottom goes: half outside the window; inside it in
    /// full screen, where there is no outside; and never under the Dock or
    /// past the screen's bottom (a window zoomed to the screen, or moved down
    /// to the Dock, would hide half of it there), nor above the window.
    static func pillY(windowFrame frame: NSRect, height: CGFloat, fullScreen: Bool, visibleFrame: NSRect?) -> CGFloat {
        if fullScreen { return frame.minY + 24 }
        var y = frame.minY - height / 2
        if let visibleFrame { y = max(y, visibleFrame.minY + dockGap) }
        return min(y, frame.maxY - height)
    }

    /// How far a pill at `pillY` reaches up into the window, with the gap above it.
    static func reach(pillY: CGFloat, height: CGFloat, windowFrame frame: NSRect) -> CGFloat {
        max(0, pillY + height - frame.minY) + roomGap
    }

    /// The pill fades in as it appears or comes back with its window.
    private func fadeIn() {
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    /// The window closed: the pill goes with it, until the window shows again.
    private func windowClosed() {
        window?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    /// For good: its window is gone.
    private func detach() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        clock.invalidate()
        panel.close()
    }
}
