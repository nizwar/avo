import AppKit
import AvoDaemonCore
import AvoKit
import SwiftUI

/// What the menu bar's panel shows: Android's state, the engine's CPU and
/// memory, the apps that run and the ones used last. Refreshed every two
/// seconds while the panel is open, and never otherwise.
@MainActor
@Observable
final class MenuBarModel {
    var status = VMStatus.stopped
    var googleAppsWork: GoogleAppsWork?
    private(set) var apps: [AppRecord] = []
    private(set) var snapshot = MenuBarSnapshot()
    /// The engine's CPU since the last refresh, in percent of one core.
    private(set) var cpuPercent: Double?
    @ObservationIgnored private var lastCPU: (time: Duration, at: ContinuousClock.Instant)?
    /// Filled while the panel draws: observed, each new icon would draw it again.
    @ObservationIgnored private var icons: [String: NSImage] = [:]

    func refresh(from core: DaemonCore) async {
        apps = await core.apps()
        snapshot = await core.menuBarSnapshot()
        let now = ContinuousClock.now
        if let time = snapshot.engine?.cpuTime {
            if let last = lastCPU, now > last.at { cpuPercent = max(0, (time - last.time) / (now - last.at) * 100) }
            lastCPU = (time, now)
        } else {
            cpuPercent = nil
            lastCPU = nil
        }
    }

    /// Apps with a window or a process, open ones first.
    var running: [(app: AppRecord, activity: AppActivity)] {
        let order: [AppActivity] = [.open, .minimized, .background]
        return apps.compactMap { app in snapshot.activity[app.package].map { (app, $0) } }
            .sorted { (order.firstIndex(of: $0.activity) ?? 3, $0.app.displayName) < (order.firstIndex(of: $1.activity) ?? 3, $1.app.displayName) }
    }

    /// The last used apps that do not run now (at most four).
    var recent: [AppRecord] {
        let byPackage = Dictionary(apps.map { ($0.package, $0) }, uniquingKeysWith: { first, _ in first })
        return snapshot.recent.filter { snapshot.activity[$0] == nil }.compactMap { byPackage[$0] }
            .filter { $0.shortcuts.shimPath != nil }.prefix(4).map { $0 }
    }

    func icon(for app: AppRecord) -> NSImage? {
        guard let shim = app.shortcuts.shimPath else { return nil }
        if let icon = icons[shim] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: shim)
        icons[shim] = icon
        return icon
    }
}

/// What the panel's buttons do (MenuBarController).
struct MenuBarActions {
    var start: () -> Void
    var pause: () -> Void
    var resume: () -> Void
    var stop: () -> Void
    var open: (AppRecord) -> Void
    var openAvo: () -> Void
    var quit: () -> Void
}

/// The menu bar item's panel, in the Library's haze: Avo's green glowing
/// over near black.
struct MenuBarPanel: View {
    let model: MenuBarModel
    let actions: MenuBarActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            statusCard
            if !model.running.isEmpty { runningApps }
            if !model.recent.isEmpty { recentApps }
            controls
        }
        .padding(16)
        .frame(width: Self.width, alignment: .leading)
        // Exactly as tall as its content: the popover takes this size and
        // places itself below the menu bar item with it.
        .fixedSize(horizontal: false, vertical: true)
        .background {
            HazeBackground(base: Haze.windowBase, glows: [
                HazeGlow(x: .fraction(0.92), y: .fraction(-0.06), rx: 240, ry: 150, color: 0xD8E8A7, alpha: 0.22),
                HazeGlow(x: .fraction(0.04), y: .fraction(1.04), rx: 220, ry: 140, color: 0xBCDC8F, alpha: 0.10),
            ])
        }
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: model.status.state)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AvoMark().frame(width: 22, height: 22)
            Text(verbatim: "Avo").font(.hubot(16, 750)).foregroundStyle(Haze.text)
            Spacer(minLength: 0)
            Button("Open Avo", action: actions.openAvo)
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 28, fontSize: 12, horizontalPadding: 12))
        }
    }

    // MARK: Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                RunningDot(size: 8, color: dotColor, pulsing: underWay)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                VStack(alignment: .leading, spacing: 3) {
                    Text(Self.title(for: model.status))
                        .font(.mona(14, 600)).foregroundStyle(Haze.text)
                        .contentTransition(reduceMotion ? .opacity : .interpolate)
                    if let subtitle {
                        Text(subtitle).font(.mona(12)).foregroundStyle(Haze.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if model.status.state == .running || model.status.isPaused, let engine = model.snapshot.engine {
                HStack(spacing: 8) {
                    stat("CPU", model.cpuPercent.map { "\(Int($0.rounded()))%" } ?? "—")
                    stat("Memory", engine.residentBytes.map {
                        ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .memory)
                    } ?? "—")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func stat(_ label: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).textCase(.uppercase).font(.hazeMono(9)).tracking(1.2).foregroundStyle(Haze.sectionLabel)
            Text(verbatim: value).font(.mona(13, 600)).foregroundStyle(Haze.text).monospacedDigit()
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.inset, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    static func title(for status: VMStatus) -> String {
        switch status.state {
        case .running: String(localized: "Android is running")
        case .suspending: String(localized: "Android is pausing…")
        case .suspended: String(localized: "Android is paused")
        case .starting: String(localized: "Android is starting…")
        case .stopping: String(localized: "Android is stopping…")
        case .stopped: String(localized: "Android is stopped")
        case .notInstalled: String(localized: "Android image not installed")
        case .failed: String(localized: "Android stopped with an error")
        }
    }

    private var subtitle: String? {
        switch model.googleAppsWork {
        case .installing?: return String(localized: "Installing Google apps…")
        case .removing?: return String(localized: "Removing Google apps…")
        case nil: break
        }
        let status = model.status
        switch status.state {
        case .running:
            var parts: [String] = []
            if let version = status.androidVersion?.components(separatedBy: " (").first { parts.append(version) }
            if let renderer = status.renderer { parts.append(renderer.mode == .gpu ? "GPU" : String(localized: "Software")) }
            if status.openDisplays > 0 { parts.append(String(localized: "\(status.openDisplays) open windows")) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .suspended, .suspending:
            return status.pause?.automatic == true
                ? String(localized: "Paused to save energy. Opening an app resumes it.")
                : String(localized: "Opening an app resumes it.")
        default:
            return status.detail
        }
    }

    private var underWay: Bool {
        [.starting, .stopping, .suspending].contains(model.status.state)
    }

    private var dotColor: Color {
        switch model.status.state {
        case .running: Haze.running
        case .starting, .stopping, .suspending: Haze.warning
        case .suspended: Haze.accent.opacity(0.55)
        case .failed: Haze.danger
        default: Haze.textTertiary
        }
    }

    // MARK: Apps

    private func sectionLabel(_ text: LocalizedStringKey) -> some View {
        Text(text).textCase(.uppercase).font(.hazeMono(10)).tracking(1.4).foregroundStyle(Haze.sectionLabel)
    }

    private var runningApps: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Running")
            ForEach(model.running.prefix(5), id: \.app.package) { entry in
                AppRow(icon: model.icon(for: entry.app), name: entry.app.displayName, detail: Self.label(entry.activity)) {
                    actions.open(entry.app)
                }
            }
        }
    }

    private var recentApps: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("Recent")
            HStack(alignment: .top, spacing: 8) {
                ForEach(model.recent, id: \.package) { app in
                    Button { actions.open(app) } label: {
                        VStack(spacing: 6) {
                            AppIcon(image: model.icon(for: app), size: 40)
                            Text(app.displayName).font(.mona(11)).foregroundStyle(Haze.textSecondary)
                                .lineLimit(1).truncationMode(.tail)
                        }
                        .frame(width: 64)
                    }
                    .buttonStyle(HazeCardButtonStyle())
                    .help(app.displayName)
                }
            }
        }
    }

    static func label(_ activity: AppActivity) -> String {
        switch activity {
        case .open: String(localized: "Open")
        case .minimized: String(localized: "Minimized")
        case .background: String(localized: "In the background")
        }
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        let state = model.status.state
        HStack(spacing: 8) {
            switch state {
            case .running:
                Button { actions.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 32, fontSize: 12, horizontalPadding: 14))
                    .help("Pause Android: it keeps its place and uses no CPU until you open an app.")
                stopButton
            case .suspended, .suspending:
                Button { actions.resume() } label: { Label("Resume", systemImage: "play.fill") }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 32, fontSize: 12, horizontalPadding: 14))
                    .disabled(state == .suspending)
                stopButton
            default:
                Button { actions.start() } label: { Label("Start", systemImage: "play.fill") }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 32, fontSize: 12, horizontalPadding: 14))
                    // The installer starts Android itself (and may be repairing it).
                    .disabled([.starting, .stopping, .notInstalled].contains(state) || model.googleAppsWork != nil)
            }
            Spacer(minLength: 0)
            Button("Quit Avo", action: actions.quit)
                .buttonStyle(HazeLinkButtonStyle())
                .font(.mona(12, 600))
                .foregroundStyle(Haze.textTertiary)
        }
    }

    private var stopButton: some View {
        Button { actions.stop() } label: { Label("Stop", systemImage: "stop.fill") }
            .buttonStyle(HazeButtonStyle(kind: .secondary, height: 32, fontSize: 12, horizontalPadding: 14))
            .help("Stop Android. Open apps close.")
    }
}

/// An app in the panel's list: its icon, name and what it is doing.
private struct AppRow: View {
    let icon: NSImage?
    let name: String
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AppIcon(image: icon, size: 28)
                Text(name).font(.mona(13, 600)).foregroundStyle(Haze.text).lineLimit(1)
                Spacer(minLength: 8)
                Text(detail).font(.mona(11)).foregroundStyle(Haze.textTertiary).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(hovering ? Haze.card : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(HazeCardButtonStyle())
        .onHover { hovering = $0 }
        .animation(Haze.Motion.hover, value: hovering)
    }
}

private struct AppIcon: View {
    let image: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Haze.tile)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
