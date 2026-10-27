import AppKit
import AvoKit
import SwiftUI
import UniformTypeIdentifiers

// The Library window: Home, the Library (every game and app, in All, Games
// and Apps tabs), Widgets, Notifications and System Status in a sidebar, and
// each app's own page over the whole window (its usage, graphics, controls
// and storage). Settings live in their own window (SettingsWindow.swift);
// the status pill floats below this one (StatusPill.swift).

enum LibrarySection: String, CaseIterable, Identifiable {
    case home, library, widgets, notifications, activity

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .library: "Library"
        case .widgets: "Widgets"
        case .notifications: "Notifications"
        case .activity: "System Status"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .library: "books.vertical"
        case .widgets: "rectangle.3.group"
        case .notifications: "bell"
        case .activity: "waveform.path.ecg"
        }
    }
}

/// The Library section's tabs: every game and app, the games, the apps.
enum LibraryTab: String, CaseIterable {
    case all, games, apps
}

/// Where the Library is, shared with the app delegate (links, the Dock) and
/// the Settings window.
@MainActor
@Observable
final class LibraryRouter {
    var section: LibrarySection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
    }
    /// The Library section's tab.
    var tab: LibraryTab {
        didSet { UserDefaults.standard.set(tab.rawValue, forKey: Self.tabKey) }
    }
    /// The app whose page covers the window.
    var page: String?
    var search = ""
    var gamesAsList: Bool {
        didSet { UserDefaults.standard.set(gamesAsList, forKey: Self.gamesListKey) }
    }
    /// A pane the Settings window should show when it next appears (a link
    /// from an app window, the Setup Assistant).
    var requestedSettingsPane: SettingsPane?
    /// An app whose page the Library should show (an app window's All
    /// Settings…); the Library brings itself forward for it.
    var requestedAppPage: String?
    /// Clear Data… or Uninstall… from an app's menu (AppTileInteraction.swift), to confirm.
    var confirmation: AppConfirmation?

    static let windowID = "library"
    static let sectionKey = "AvoLibrarySection"
    static let tabKey = "AvoLibraryTab"
    static let gamesListKey = "AvoLibraryGamesAsList"

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.sectionKey)
        tab = UserDefaults.standard.string(forKey: Self.tabKey).flatMap(LibraryTab.init(rawValue:)) ?? .all
        // Games and Apps were sections of their own before they were the Library's tabs.
        if let old = saved.flatMap(LibraryTab.init(rawValue:)), old != .all {
            section = .library
            tab = old
        } else {
            section = saved.flatMap(LibrarySection.init(rawValue:)) ?? .home
        }
        gamesAsList = UserDefaults.standard.bool(forKey: Self.gamesListKey)
    }

    func show(_ section: LibrarySection) {
        page = nil
        if self.section != section { search = "" }
        self.section = section
    }

    /// The Library section at `tab` (Home's See All).
    func showLibrary(_ tab: LibraryTab) {
        show(.library)
        self.tab = tab
    }

    func open(_ app: AppRecord) {
        page = app.package
    }
}

struct LibraryView: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false
    /// Where the pointer is, for the haze, the cards and the icons.
    @State private var pointer = HazePointer()
    /// The bottom of the window the status pill takes.
    @State private var pillRoom = StatusPillRoom()

    var body: some View {
        @Bindable var model = model
        ZStack {
            if let package = router.page, let app = model.apps.first(where: { $0.package == package }) {
                // Into a page: it comes forward as the Library steps back; out
                // of it, the other way round.
                AppPage(app: app)
                    .id(package)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.985, anchor: .top)))
            } else {
                HStack(spacing: 0) {
                    LibrarySidebar()
                    LibraryMain()
                        // The section ends above the status pill, which covers none of it.
                        .padding(.bottom, pillRoom.bottom)
                }
                .background { HazeWindowBackground() }
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.99)))
            }
            if dropTargeted {
                HazeDropOverlay()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 1.02)))
            }
        }
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: router.page)
        .animation(Haze.Motion.animation(Haze.Motion.hover, reduceMotion: reduceMotion), value: dropTargeted)
        .windowDragArea()
        .ignoresSafeArea()
        .hazeTracksPointer(pointer)
        // The pointer effects rest while the window is in the background.
        .onChange(of: appearsActive && !reduceMotion, initial: true) { _, live in pointer.setLive(live) }
        .onDisappear { pointer.detach() }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.apps.map(\.package)) { _, packages in
            // An app uninstalled while its page showed.
            if let page = router.page, !packages.contains(page) { router.page = nil }
        }
        .sheet(item: $model.installSheet) { _ in
            InstallSheet()
        }
        .sheet(isPresented: $model.unlockSheetShown) {
            if let lock = model.screenLock { UnlockAndroidSheet(lock: lock) }
        }
        .modifier(AppConfirmations())
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil && appearsActive },
                                                            set: { if !$0 { model.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.lastError ?? "")
        }
        .presentsSetupAssistant()
        // A Settings pane asked for (a link from an app window, the Setup
        // Assistant): the Settings window shows it.
        .onChange(of: router.requestedSettingsPane, initial: true) { _, pane in
            if pane != nil { openWindow(id: SettingsWindow.id) }
        }
        // An app's page asked for (All Settings… in its window): over the
        // Library, which comes forward.
        .onChange(of: router.requestedAppPage, initial: true) { _, package in
            guard let package else { return }
            router.requestedAppPage = nil
            router.page = package
            openWindow(id: LibraryRouter.windowID)
        }
        // An app's page ends above the pill too (AppPage).
        .environment(pillRoom)
        .background { LibraryWindowAccessor(pointer: pointer, pillRoom: pillRoom) }
    }

    /// Spec §3: dragging packages onto the window installs them, in turn.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !files.isEmpty else { return false }
        for provider in files {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.prepareInstall(url) }
            }
        }
        return true
    }
}

/// The content beside the sidebar: the top bar (search, the Library's tabs,
/// Install App) over Home and the Library; the other sections have their own
/// headers.
private struct LibraryMain: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // A new section fades in, rising a little, over the one leaving.
        let arrival = Haze.Motion.arrival(reduceMotion: reduceMotion)
        VStack(alignment: .leading, spacing: 0) {
            LibraryBanners()
            ZStack(alignment: .topLeading) {
                switch router.section {
                case .notifications:
                    LibraryNotifications()
                        .transition(arrival)
                case .activity:
                    SystemStatusView()
                        .transition(arrival)
                case .widgets:
                    LibraryWidgets()
                        .transition(arrival)
                case .home, .library:
                    VStack(alignment: .leading, spacing: 26) {
                        LibraryTopBar()
                            .padding(.horizontal, 34)
                        ZStack(alignment: .topLeading) {
                            if router.section == .library {
                                switch router.tab {
                                case .all: LibraryAllCollection().transition(arrival)
                                case .games: GamesCollection().transition(arrival)
                                case .apps: AppsCollection().transition(arrival)
                                }
                            } else if router.search.isEmpty {
                                LibraryHome().transition(arrival)
                            } else {
                                SearchResults().transition(arrival)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: router.tab)
                    }
                    .padding(.top, 20)
                    .transition(arrival)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: router.section)
            .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: router.search.isEmpty)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Search, the Library's All / Games / Apps tabs and Install App.
private struct LibraryTopBar: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var router = router
        HStack(spacing: 14) {
            HazeSearchField(text: $router.search, prompt: "Search apps and games")
                .frame(maxWidth: 368)
            if router.section == .library {
                // The search stays as the tab changes.
                HazeSegmented(options: [(LibraryTab.all, Text("All")), (.games, Text("Games")), (.apps, Text("Apps"))],
                              selection: $router.tab)
                    .fixedSize()
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -8)))
            }
            Spacer(minLength: 0)
            Button {
                model.chooseAndInstall()
            } label: {
                Label("Install App", systemImage: "arrow.down.to.line")
                    .labelStyle(HazeLabelStyle(spacing: 8, iconSize: 14))
            }
            .buttonStyle(HazeButtonStyle(kind: .secondary))
            .help("Install an .apk, .xapk, .apkm or .apks file")
        }
        .frame(height: 38)
    }
}

/// A rounded search field in the design's veil.
struct HazeSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    /// Bumped to put the focus in the field (⌘F in Settings).
    var focusRequest = 0
    @FocusState private var focused: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(focused ? Haze.accent : Haze.textTertiary)
            TextField(prompt, text: $text, prompt: Text(prompt).foregroundStyle(Haze.textTertiary))
                .textFieldStyle(.plain)
                .font(.mona(14))
                .foregroundStyle(Haze.text)
                .focused($focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Haze.textTertiary)
                }
                .buttonStyle(HazeLinkButtonStyle())
                .accessibilityLabel(Text("Clear"))
                .transition(.opacity.combined(with: .scale(scale: 0.7)))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background {
            ZStack {
                Capsule().fill(Haze.field)
                Capsule().fill(Haze.text.opacity(hovering && !focused ? 0.03 : 0))
            }
        }
        .overlay { Capsule().strokeBorder(Haze.accent.opacity(focused ? 0.35 : 0)) }
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .onChange(of: focusRequest) { focused = true }
        .hazeHover($hovering)
        .animation(Haze.Motion.hover, value: focused)
        .animation(Haze.Motion.hover, value: text.isEmpty)
    }
}

/// Icon and title with the design's spacing.
struct HazeLabelStyle: LabelStyle {
    var spacing: CGFloat = 8
    var iconSize: CGFloat = 14

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: spacing) {
            configuration.icon.font(.system(size: iconSize, weight: .semibold))
            configuration.title
        }
    }
}

// MARK: - Banners

/// What needs the user now, above the content: the background service, the
/// Android image (Setup Assistant), the screen lock, a restart, the GPU.
/// The same states and words as the old window's banners, in the haze.
struct LibraryBanners: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(SetupAssistant.self) private var assistant
    @Environment(AndroidImageManager.self) private var images
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
            // Opened where it was downloaded: its background service would be
            // registered in a place macOS removes.
            if model.runsFromTemporaryCopy {
                HazeBanner(symbol: "exclamationmark.triangle", tint: Haze.warning,
                           text: "Avo is running from a temporary copy macOS made of it. Quit Avo, move it to the Applications folder, and open it from there.")
            }
            LibrarySetupBanner()
            // Android's data is on a drive that is not connected (StorageLocationViews.swift).
            StorageProblemBanner()
            // Android waits for room on its data's drive, or little is left there.
            StorageSpaceBanner()
            if model.screenLock != nil, model.daemonState == .connected {
                HazeBanner(symbol: "lock.fill", tint: Haze.warning,
                           text: "Android is locked by its screen lock. Your apps open after you unlock it.") {
                    Button("Unlock…") { model.unlockSheetShown = true }
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
            if model.status.renderer?.reason == .failed, model.config?.rendererMode != .software {
                HazeBanner(symbol: "exclamationmark.triangle", tint: Haze.warning,
                           text: "GPU rendering failed to start, so Android uses software rendering.") {
                    Button("Try GPU Again") { model.retryGPU() }
                        .disabled(model.googleAppsChangingAndroid)
                }
            }
        }
        .padding(.horizontal, 34)
        .padding(.top, hasBanner ? 20 : 0)
        // Banners come and go smoothly, the content below making room.
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: bannerState)
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: hasStorageBanner)
    }

    private var bannerState: [Bool] {
        [model.daemonState == .connected, model.daemonState == .connecting, model.daemonState == .needsApproval,
         model.runsFromTemporaryCopy, model.screenLock != nil, model.status.isNotResponding, model.pendingRestart,
         images.needsImage && !assistant.isPresented,
         model.status.renderer?.reason == .failed && model.config?.rendererMode != .software]
    }

    private var hasBanner: Bool {
        model.daemonState != .connected || model.runsFromTemporaryCopy
            || (model.screenLock != nil && model.daemonState == .connected) || model.status.isNotResponding || model.pendingRestart
            || (images.needsImage && !assistant.isPresented)
            || (model.status.renderer?.reason == .failed && model.config?.rendererMode != .software)
            || hasStorageBanner
    }

    /// StorageProblemBanner or StorageSpaceBanner shows.
    private var hasStorageBanner: Bool {
        model.daemonState == .connected && (model.storageLocation?.problem != nil || model.storageLocation?.space != nil)
    }
}

/// A banner in the haze: a tinted card with its symbol, text and actions.
struct HazeBanner<Actions: View>: View {
    let symbol: String
    let tint: Color
    let text: LocalizedStringKey
    @ViewBuilder var actions: Actions

    init(symbol: String, tint: Color, text: LocalizedStringKey, @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.symbol = symbol
        self.tint = tint
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.mona(13))
                .foregroundStyle(Haze.text)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 14))
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(tint.opacity(0.18)) }
        .transition(.opacity.combined(with: .offset(y: -6)))
    }
}

/// Shown while dragging a package over the window: the drop target glows
/// and breathes while the package is over it.
private struct HazeDropOverlay: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        HazeLoop(period: 2.2) { phase in
            // 0…1…0, easing in and out.
            let breath = 0.5 - 0.5 * cos(phase * 2 * .pi)
            ZStack {
                shape.fill(Haze.accent.opacity(0.06 + 0.06 * breath))
                // A soft inner glow along the edge.
                shape.strokeBorder(Haze.accent.opacity(0.08 + 0.10 * breath), lineWidth: 14)
                shape.strokeBorder(Haze.accent.opacity(0.75 + 0.25 * breath), style: StrokeStyle(lineWidth: 2, dash: [10, 6]))
            }
            .scaleEffect(reduceMotion ? 1 : 1 - 0.004 * breath)
        }
        .overlay {
            Label("Drop to install", systemImage: "arrow.down.app")
                .font(.hubot(22, 700))
                .foregroundStyle(Haze.accent)
                .symbolEffect(.breathe, isActive: !reduceMotion)
        }
        .padding(14)
        .allowsHitTesting(false)
    }
}

// MARK: - Window

/// Sets up the window the Library lives in: dark, its background the haze
/// colour (also behind the corners while resizing), a sensible minimum
/// size, and the status pill as a child panel below it.
private struct LibraryWindowAccessor: NSViewRepresentable {
    @Environment(ControlPanelModel.self) private var model
    let pointer: HazePointer
    let pillRoom: StatusPillRoom

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        let model = self.model
        let openWindow = context.environment.openWindow
        let pointer = self.pointer
        let pillRoom = self.pillRoom
        view.onWindow = { window in
            pointer.attach(to: window)
            window.backgroundColor = NSColor(Haze.windowBase)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 980, height: 640)
            StatusPillController.attach(to: window, model: model, room: pillRoom) { openWindow(id: SettingsWindow.id) }
        }
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {}
}

/// Hands its window to `onWindow` once it is in one.
final class WindowAccessorView: NSView {
    var onWindow: ((NSWindow) -> Void)?
    private weak var configured: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, window !== configured else { return }
        configured = window
        onWindow?(window)
    }
}

/// Clear Data… and Uninstall… from an app's menu, confirmed as on its page.
private struct AppConfirmations: ViewModifier {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    func body(content: Content) -> some View {
        let pending = router.confirmation
        content
            .confirmationDialog(pending.map { String(localized: "Uninstall \($0.app.displayName)?") } ?? "",
                                isPresented: binding(.uninstall), titleVisibility: .visible, presenting: pending) { pending in
                Button("Uninstall", role: .destructive) { model.uninstall(pending.app) }
            } message: { _ in
                Text("The app, its data and its shortcut in Android Apps are removed.")
            }
            .confirmationDialog(pending.map { Text("Clear all data of \($0.app.displayName)?") } ?? Text(verbatim: ""),
                                isPresented: binding(.clearData), titleVisibility: .visible, presenting: pending) { pending in
                Button("Clear Data", role: .destructive) { model.deleteData(pending.app) }
            } message: { _ in
                Text("Accounts, settings and files stored by the app are deleted.")
            }
    }

    private func binding(_ kind: AppConfirmation.Kind) -> Binding<Bool> {
        Binding(get: { router.confirmation?.kind == kind }, set: { if !$0 { router.confirmation = nil } })
    }
}
