import AppKit
import AvoKit
import SwiftUI

// Settings, in a window of its own laid out like System Settings and dressed
// like the Library: the haze behind everything, a sidebar of coloured symbol
// tiles in groups with a search field above them and Android's status on top,
// and the pane on the right under back, forward and its title, its sections
// as cards (HazeFormStyle). The panes are the Control Panel's own
// (SettingsPanes.swift and the others), Android's system first, then how apps
// look and run, then what they learn, and the developer's last; every
// setting lives in one pane.

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, android, googleApps, performance, storage
    case graphics, devices
    case privacy, fingerprints
    case developer, about

    var id: String { rawValue }

    static let groups: [[SettingsPane]] = [
        [.general, .android, .googleApps, .performance, .storage],
        [.graphics, .devices],
        [.privacy, .fingerprints],
        [.developer, .about],
    ]

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .android: "Android"
        case .googleApps: "Google Apps"
        case .graphics: "Graphics"
        case .devices: "Devices"
        case .performance: "Performance"
        case .storage: "Storage"
        case .fingerprints: "Fingerprints"
        case .privacy: "Privacy & Security"
        case .developer: "Developer"
        case .about: "About Avo"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .android: "candybarphone"
        case .googleApps: "play.fill"
        case .graphics: "cpu"
        case .devices: "antenna.radiowaves.left.and.right"
        case .performance: "gauge.with.dots.needle.67percent"
        case .storage: "internaldrive.fill"
        case .fingerprints: "touchid"
        case .privacy: "hand.raised.fill"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .about: "info.circle"
        }
    }

    /// The tile's colour (System Settings' palette, Avo's green for Avo's own).
    var tint: Color {
        switch self {
        case .general, .storage: Color(haze: 0x8E8E93)
        case .android, .about: Color(haze: 0x4F7A2F)
        case .googleApps: Color(haze: 0x2F9E52)
        case .graphics: Color(haze: 0x7A5AF5)
        case .devices: Color(haze: 0x0A84FF)
        case .performance: Color(haze: 0xFF9F0A)
        case .fingerprints: Color(haze: 0xFF375F)
        case .privacy: Color(haze: 0x5E5CE6)
        case .developer: Color(haze: 0x30B0C7)
        }
    }

    /// Words the search also finds the pane by.
    var keywords: [String] {
        switch self {
        case .general: [String(localized: "Appearance"), String(localized: "Dark mode"), String(localized: "Light mode"),
                        String(localized: "Shortcuts"), String(localized: "Dock"), String(localized: "Desktop alias"),
                        String(localized: "Notifications"), String(localized: "Notification Center"),
                        String(localized: "Translate Screen"), String(localized: "Translation"), String(localized: "Translate into")]
        case .android: [String(localized: "Android version"), String(localized: "Checkpoints"), String(localized: "Restore"),
                        String(localized: "Reset Android")]
        case .googleApps: [String(localized: "Google Play"), "MindTheGapps", "GApps", String(localized: "Android ID")]
        // Display was a pane of its own: its settings are in Graphics now.
        case .graphics: [String(localized: "Resolution"), "MetalFX", String(localized: "Sharpness"), String(localized: "Renderer"),
                         String(localized: "Frame rate"), "FPS", "GPU", "4K", String(localized: "Aspect ratio"),
                         String(localized: "Screen size"), String(localized: "Upscaling"), String(localized: "Display"), String(localized: "Default window size"),
                         String(localized: "Orientation"), String(localized: "Performance HUD"), "HUD",
                         String(localized: "Max FPS"), String(localized: "Preset"), String(localized: "Smooth edges"),
                         String(localized: "Sharp upscaling"), String(localized: "Render scale"), String(localized: "App bar style"),
                         String(localized: "Phone style"), String(localized: "Heavy game")]
        case .devices: ["Wi-Fi", "Bluetooth", String(localized: "Location"), "GPS", String(localized: "Network speed"),
                        "5G", "4G", "LTE", "3G", "EDGE", String(localized: "Offline"), "SIM", String(localized: "Mobile network"),
                        String(localized: "Mobile data"), String(localized: "Signal"), String(localized: "Cameras"),
                        String(localized: "Camera"), "Webcam", String(localized: "Sound"), String(localized: "Volume"),
                        String(localized: "Microphone"), String(localized: "Clipboard"),
                        String(localized: "Privacy"), String(localized: "Scrolling"), String(localized: "Mouse"),
                        String(localized: "Trackpad"), String(localized: "Screen recording")]
        case .performance: [String(localized: "Memory"), "RAM", String(localized: "CPU cores")]
        case .storage: [String(localized: "Data disk"), String(localized: "Android storage"), String(localized: "GPU shader cache"),
                        String(localized: "Location"), String(localized: "External drive"), String(localized: "Shared Folder"),
                        String(localized: "Avo Shared")]
        case .fingerprints: [String(localized: "Fingers")]
        case .privacy: [String(localized: "Identify as"), String(localized: "Device profile"),
                        String(localized: "Emulate this phone’s hardware")]
        case .developer: ["ADB", "adb", "scrcpy", "Android Studio"]
        case .about: [String(localized: "Version"), String(localized: "Software Update"), String(localized: "Check for Updates")]
        }
    }

    func matches(_ search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return titleString.localizedCaseInsensitiveContains(query)
            || keywords.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// The title as a string (for search).
    var titleString: String {
        switch self {
        case .general: String(localized: "General")
        case .android: String(localized: "Android")
        case .googleApps: String(localized: "Google Apps")
        case .graphics: String(localized: "Graphics")
        case .devices: String(localized: "Devices")
        case .performance: String(localized: "Performance")
        case .storage: String(localized: "Storage")
        case .fingerprints: String(localized: "Fingerprints")
        case .privacy: String(localized: "Privacy & Security")
        case .developer: String(localized: "Developer")
        case .about: String(localized: "About Avo")
        }
    }

    /// The pane an older name means (`-AvoSelectedPane`, app windows' links).
    static func named(_ name: String) -> SettingsPane? {
        if let pane = SettingsPane(rawValue: name) { return pane }
        switch name {
        case "system": return .googleApps
        case "notifications": return .general
        case "location": return .devices
        case "display": return .graphics
        default: return nil
        }
    }
}

struct SettingsWindow: View {
    static let id = "settings"
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @AppStorage("AvoSettingsPane") private var stored: SettingsPane = .general
    @State private var selection: SettingsPane?
    @State private var back: [SettingsPane] = []
    @State private var forward: [SettingsPane] = []
    /// A move through back or forward, which keeps the history.
    @State private var travelling = false
    @State private var search = ""
    /// Where the pointer is, for the haze, the cards and the tiles.
    @State private var pointer = HazePointer()
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let pane = selection ?? stored
        HStack(spacing: 0) {
            SettingsSidebar(selection: $selection, current: pane, search: $search)
            VStack(alignment: .leading, spacing: 0) {
                SettingsTopBar(pane: pane, canGoBack: !back.isEmpty, canGoForward: !forward.isEmpty) { go(back: $0) }
                SettingsBanners()
                // Panes cross-fade (a quick one: this window is System Settings-like).
                ZStack {
                    SettingsDetail(pane: pane)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Each pane starts scrolled to the top, its cards rising in.
                        .id(pane)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.16), value: pane)
            }
            // Wide windows: a readable column in the middle, its title over its cards.
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .windowDragArea()
        .background { HazeWindowBackground() }
        .ignoresSafeArea()
        .navigationTitle(pane.title)
        .frame(minWidth: 820, minHeight: 540)
        .hazeTracksPointer(pointer)
        // The pointer effects rest while the window is in the background.
        .onChange(of: appearsActive && !reduceMotion, initial: true) { _, live in pointer.setLive(live) }
        .onDisappear { pointer.detach() }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        // What a Settings action could not do (as in the Library window).
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil && appearsActive },
                                                            set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .presentsSetupAssistant()
        .onAppear {
            // A pane stored under an older name (Display) opens where it went.
            let remembered = UserDefaults.standard.string(forKey: "AvoSettingsPane").flatMap(SettingsPane.named) ?? stored
            if selection == nil { selection = takeRequest() ?? remembered }
        }
        .onChange(of: router.requestedSettingsPane) {
            if let pane = takeRequest() { selection = pane }
        }
        // An app's page asked for while the Library was closed: it opens and shows it.
        .onChange(of: router.requestedAppPage) { _, package in
            if package != nil { openWindow(id: LibraryRouter.windowID) }
        }
        // A package to install while the Library was closed (double-click,
        // the Dock icon, ⌘O): its sheet is the Library's.
        .onChange(of: model.pendingInstall?.id) { _, id in
            if id != nil { openWindow(id: LibraryRouter.windowID) }
        }
        .onChange(of: selection) { old, new in
            guard let new else { return }
            stored = new
            if travelling {
                travelling = false
            } else if let old, old != new {
                back.append(old)
                forward.removeAll()
            }
        }
        .onChange(of: search) {
            // The first result shows while searching, as in System Settings.
            let matches = SettingsPane.groups.flatMap { $0 }.filter { $0.matches(search) }
            if !search.isEmpty, let first = matches.first, !matches.contains(selection ?? stored) { selection = first }
        }
        .background { SettingsWindowAccessor(pointer: pointer) }
    }

    private func takeRequest() -> SettingsPane? {
        guard let pane = router.requestedSettingsPane else { return nil }
        router.requestedSettingsPane = nil
        return pane
    }

    private func go(back isBack: Bool) {
        guard let current = selection else { return }
        if isBack, let previous = back.popLast() {
            forward.append(current)
            travelling = true
            selection = previous
        } else if !isBack, let next = forward.popLast() {
            back.append(current)
            travelling = true
            selection = next
        }
    }
}

/// Back, forward (⌘[ and ⌘]) and the pane's title with its tile, which
/// turns toward the pointer and catches its light.
private struct SettingsTopBar: View {
    let pane: SettingsPane
    let canGoBack: Bool
    let canGoForward: Bool
    let go: (_ back: Bool) -> Void

    var body: some View {
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { go(true) } label: {
                    Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                }
                .disabled(!canGoBack)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back")
                .accessibilityLabel(Text("Back"))
                Button { go(false) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                }
                .disabled(!canGoForward)
                .keyboardShortcut("]", modifiers: .command)
                .help("Forward")
                .accessibilityLabel(Text("Forward"))
            }
            .buttonStyle(HazeIconButtonStyle(size: 30, fill: Haze.text.opacity(0.06), foreground: Haze.textSecondary))
            HStack(spacing: 11) {
                SettingsTile(symbol: pane.symbol, tint: pane.tint, size: 28)
                    .hazeEdgeLight(cornerRadius: 28 * 0.225, reach: 120)
                    .hazeTilt(degrees: 10, reach: 200)
                Text(pane.title)
                    .font(.hubot(21, 750))
                    .tracking(-0.3)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            .id(pane)
            .transition(.opacity)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 34)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(height: 60, alignment: .top)
        .animation(.easeInOut(duration: 0.16), value: pane)
    }
}

/// The sidebar: the search field, Android's status, then the panes in
/// groups, filtered by the search. The arrow keys move through the panes
/// once the list has the focus (a click on a pane gives it), ⌘F searches.
struct SettingsSidebar: View {
    @Binding var selection: SettingsPane?
    /// The pane shown (`selection`, or the remembered one before it is set).
    let current: SettingsPane
    @Binding var search: String
    @FocusState private var listFocused: Bool
    @State private var searchFocus = 0
    /// The selection's highlight, which slides from row to row.
    @Namespace private var highlight
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let groups = SettingsPane.groups.map { $0.filter { $0.matches(search) } }.filter { !$0.isEmpty }
        VStack(alignment: .leading, spacing: 0) {
            HazeSearchField(text: $search, prompt: "Search", focusRequest: searchFocus)
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    SettingsStatusHeader()
                        .padding(.bottom, 12)
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(group) { pane in
                                SettingsSidebarRow(pane: pane, selected: pane == current, focused: listFocused, highlight: highlight) {
                                    selection = pane
                                    listFocused = true
                                }
                            }
                        }
                        .padding(.top, index == 0 ? 0 : 12)
                    }
                    if groups.isEmpty {
                        Text("No Results")
                            .font(.mona(13))
                            .foregroundStyle(Haze.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, 6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 16)
            }
            .windowDragArea()
            .scrollIndicators(.never)
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onMoveCommand { direction in move(direction, among: groups.flatMap { $0 }) }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Settings"))
        }
        .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: current)
        .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: groups)
        .padding(.top, 52)
        // 236 points of rows inside 14-point margins, as in the Library.
        .frame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Haze.sidebar)
        .background {
            // ⌘F: the search field.
            Button("Search") { searchFocus += 1 }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    /// ↑ and ↓ through the panes the search shows.
    private func move(_ direction: MoveCommandDirection, among panes: [SettingsPane]) {
        guard let index = panes.firstIndex(of: current) else {
            if let first = panes.first { selection = first }
            return
        }
        switch direction {
        case .up where index > 0: selection = panes[index - 1]
        case .down where index < panes.count - 1: selection = panes[index + 1]
        default: break
        }
    }
}

/// A sidebar row: the coloured tile with its white symbol, and the title;
/// the selection's light slides to it.
struct SettingsSidebarRow: View {
    let pane: SettingsPane
    let selected: Bool
    /// The list has the keyboard focus: the selection's edge lights up.
    let focused: Bool
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 11) {
                SettingsTile(symbol: pane.symbol, tint: pane.tint, size: 22)
                    .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                Text(pane.title)
                    .font(.mona(13.5, selected ? 600 : 400))
                    .foregroundStyle(selected ? Haze.accentText : (hovering ? Haze.text : Haze.textSecondary))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                ZStack {
                    shape.fill(Haze.text.opacity(hovering && !selected ? 0.05 : 0))
                    if selected {
                        shape.fill(Haze.selection)
                            .overlay { shape.strokeBorder(Haze.accent.opacity(focused ? 0.45 : 0)) }
                            .matchedGeometryEffect(id: reduceMotion ? AnyHashable(pane) : AnyHashable("selection"), in: highlight)
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(HazeCardButtonStyle())
        .hazeHover($hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// System Settings' rounded tile. Every symbol is fitted into the same
/// centred box (68% of the tile wide, 60% high), so wide ones (Developer's
/// brackets, Storage's drive) keep clear of the edges and tall ones
/// (Android's phone) look the same size, as in System Settings; a symbol
/// sized by its font would not.
struct SettingsTile: View {
    let symbol: String
    let tint: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .resizable()
                    .fontWeight(.semibold)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size * 0.68, height: size * 0.6)
                    .foregroundStyle(.white)
            }
            // A breath of light on the top edge, as on the Library's tiles.
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.28), .white.opacity(0)], startPoint: .top, endPoint: .bottom),
                                  lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}

/// Android's state on top of the sidebar, like the account row in System Settings.
private struct SettingsStatusHeader: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(EllipticalGradient(colors: [Color(haze: 0xD8E8A7, alpha: 0.55), Color(haze: 0x2F4A1F)],
                                             center: UnitPoint(x: 0.7, y: 0.25), startRadiusFraction: 0, endRadiusFraction: 0.7))
                AvoMark(showsSkin: false).frame(width: 24, height: 24)
            }
            .frame(width: 38, height: 38)
            .hazeEdgeLight(cornerRadius: 10, reach: 140)
            .hazeTilt(degrees: 8, reach: 180)
            VStack(alignment: .leading, spacing: 3) {
                Text(StatusPill.shortVersion(model.status.androidVersion) ?? "Android")
                    .font(.hubot(15, 700))
                    .foregroundStyle(Haze.text)
                HStack(spacing: 6) {
                    RunningDot(size: 6, color: dotColor, pulsing: model.status.state.isBusy)
                    Text(detail)
                        .font(.mona(12))
                        .foregroundStyle(Haze.textTertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.text.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var dotColor: Color {
        guard model.daemonState == .connected else { return Haze.textTertiary }
        switch model.status.state {
        case .running: return model.status.isNotResponding ? Haze.warning : Haze.running
        case .failed: return Haze.danger
        case .starting, .stopping, .suspending: return Haze.warning
        default: return Haze.textTertiary
        }
    }

    /// "Running · GPU".
    private var detail: String {
        guard model.daemonState == .connected else { return String(localized: "Not connected") }
        // It runs, but stopped answering: not "Running" (the banner offers a restart).
        if model.status.isNotResponding { return String(localized: "Not responding") }
        var text = String(localized: model.status.state.labelResource)
        if model.status.state == .running, let renderer = model.status.renderer {
            text += " · " + (renderer.mode == .gpu ? "GPU" : String(localized: "Software"))
        }
        return text
    }
}

extension VMState {
    var labelResource: LocalizedStringResource {
        switch self {
        case .notInstalled: "Android not installed"
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .running: "Running"
        case .suspending: "Pausing"
        case .suspended: "Paused"
        case .stopping: "Stopping"
        case .failed: "Stopped with an error"
        }
    }
}

/// The pane itself: the Control Panel's own views, their forms as cards in the haze.
private struct SettingsDetail: View {
    let pane: SettingsPane

    var body: some View {
        Group {
            switch pane {
            case .general: GeneralPane()
            case .android: SystemPane(sections: [.androidVersion, .checkpoints, .maintenance])
            case .googleApps: SystemPane(sections: .googleApps)
            case .graphics: GraphicsPane()
            case .performance: PerformancePane()
            case .storage: StoragePane()
            case .fingerprints: FingerprintsPane()
            case .devices: SystemPane(sections: [.network, .mobile, .bluetooth, .cameras, .sound, .microphone, .location, .clipboard, .scrolling])
            case .privacy: SystemPane(sections: .identity)
            case .developer: SystemPane(sections: .developer)
            case .about: AboutPane()
            }
        }
        .formStyle(HazeFormStyle())
    }
}

/// What needs the user before any setting: the background service, a
/// restart, the GPU. The Library's banners, in the same words.
private struct SettingsBanners: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 8) {
            switch model.daemonState {
            case .connected:
                EmptyView()
            case .connecting:
                HazeBanner(symbol: "hourglass", tint: Haze.textTertiary, text: "Connecting to Avo’s background service…")
            case .needsApproval:
                HazeBanner(symbol: "exclamationmark.shield", tint: Haze.warning,
                           text: "Allow Avo in System Settings › General › Login Items & Extensions so Android can run in the background.") {
                    Button("Open System Settings") { model.openLoginItemsSettings() }
                }
            case .unavailable(let reason):
                HazeBanner(symbol: "bolt.horizontal.circle", tint: Haze.danger, text: "Avo’s background service is not running. \(reason)") {
                    Button("Retry") { model.retryDaemon() }
                }
            }
            // Android runs but stopped answering (HostAgent's check): a restart is the way on.
            if model.status.isNotResponding {
                HazeBanner(symbol: "exclamationmark.triangle", tint: Haze.warning,
                           text: "Android stopped answering. Restart it to go on: your apps and data are kept.") {
                    Button("Restart Android") { model.restartVM() }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
            if model.pendingRestart {
                HazeBanner(symbol: "arrow.clockwise.circle", tint: Haze.accent,
                           text: "Some changes apply after Android restarts. Your apps and data are kept.") {
                    Button("Restart Android") { model.restartVM() }
                        .disabled(model.status.state != .running || model.googleAppsChangingAndroid)
                }
            }
            if gpuFailed {
                HazeBanner(symbol: "exclamationmark.triangle", tint: Haze.warning,
                           text: "GPU rendering failed to start, so Android uses software rendering.") {
                    Button("Try GPU Again") { model.retryGPU() }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.bottom, hasBanner ? 8 : 0)
        // Banners come and go smoothly, the pane below making room.
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: [hasBanner, model.pendingRestart, gpuFailed])
    }

    private var gpuFailed: Bool { model.status.renderer?.reason == .failed && model.config?.rendererMode != .software }
    private var hasBanner: Bool { model.daemonState != .connected || model.pendingRestart || gpuFailed }
}

/// Sets up the window Settings live in, as the Library's: dark, its
/// background the haze colour, the title bar clear over the content.
private struct SettingsWindowAccessor: NSViewRepresentable {
    let pointer: HazePointer

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        let pointer = self.pointer
        view.onWindow = { window in
            pointer.attach(to: window)
            window.backgroundColor = NSColor(Haze.windowBase)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

// MARK: - About

/// Avo's version, and what runs Android on this Mac.
struct AboutPane: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        Form {
            Section {
                HStack(spacing: 18) {
                    // The icon turns toward the pointer and catches its light.
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable()
                        .frame(width: 72, height: 72)
                        .shadow(color: Haze.shadow.opacity(0.45), radius: 16, y: 10)
                        .hazeEdgeLight(cornerRadius: 16, reach: 220)
                        .hazeTilt(degrees: 7, reach: 360)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: "Avo")
                            .font(.hubot(30, 800))
                            .tracking(-0.4)
                        Text("Android apps and games on your Mac")
                            .font(.mona(14))
                            .foregroundStyle(Haze.textSecondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Version") {
                    Text(verbatim: Self.version).textSelection(.enabled)
                }
            }
            SoftwareUpdateSection()
            Section("Android") {
                LabeledContent("Version") {
                    model.status.androidVersion.map { Text(verbatim: $0) } ?? Text("Not running")
                }
                if let renderer = model.status.renderer {
                    LabeledContent("Renderer") {
                        if renderer.mode == .gpu {
                            Text(verbatim: ["GPU", renderer.detail].compactMap { $0 }.joined(separator: " · "))
                        } else {
                            Text("Software")
                        }
                    }
                }
            }
            Section("This Mac") {
                let host = model.host
                LabeledContent("macOS") { Text(verbatim: host.macOSVersion) }
                LabeledContent("CPU cores") {
                    Text("\(host.performanceCores) performance, \(host.efficiencyCores) efficiency")
                }
                LabeledContent("Memory") {
                    Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(host.physicalMemoryBytes), countStyle: .memory))
                }
            }
        }
    }

    /// "0.1.0 (1)": the version, then the build (CFBundleVersion), which every release raises.
    static var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }
}

/// Settings › About › Software Update: Avo's own updates (AppUpdater.swift).
private struct SoftwareUpdateSection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(AppUpdater.self) private var updater

    var body: some View {
        Section("Software Update") {
            if case .ready = updater.readiness {
                Toggle(isOn: Binding(get: { updater.automaticallyChecks }, set: { updater.setAutomaticallyChecks($0) })) {
                    HelpTitle("Check for updates automatically",
                              help: "Once a day, Avo looks for a new version. It asks before installing one, and before an update stops Android.")
                }
                LabeledContent {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                        .disabled(!updater.canCheckForUpdates)
                } label: {
                    if let last = updater.lastCheck {
                        Text("Last checked \(last, format: .relative(presentation: .named))")
                    } else {
                        Text("Not checked yet")
                    }
                }
            } else {
                RestartNote(text: "This build of Avo has no update feed: new versions come as a download.")
            }
            if model.daemonUpdatePending {
                LabeledContent {
                    Button("Restart Android") { model.restartAndroidForUpdate() }
                } label: {
                    HelpTitle("Android runs the previous version",
                              help: "Avo was updated while Android was running. Android keeps running as it was, and moves to the new version the next time it stops. Restart Android does that now: save your progress in open games first.")
                }
            }
        }
        .onAppear { updater.refresh() }
    }
}
