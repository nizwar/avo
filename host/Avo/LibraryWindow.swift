import AppKit
import AvoKit
import SwiftUI
import UniformTypeIdentifiers

// The Library window: Home, Games, Apps, Notifications and System Status in
// a sidebar, and each app's own page over the whole window (its usage,
// graphics, controls and storage). Settings live in their own window (SettingsWindow.swift);
// the status pill floats below this one (StatusPill.swift).

enum LibrarySection: String, CaseIterable, Identifiable {
    case home, games, apps, widgets, notifications, activity

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .home: "Home"
        case .games: "Games"
        case .apps: "Apps"
        case .widgets: "Widgets"
        case .notifications: "Notifications"
        case .activity: "System Status"
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .games: "gamecontroller"
        case .apps: "square.grid.2x2"
        case .widgets: "rectangle.3.group"
        case .notifications: "bell"
        case .activity: "waveform.path.ecg"
        }
    }
}

/// Where the Library is, shared with the app delegate (links, the Dock) and
/// the Settings window.
@MainActor
@Observable
final class LibraryRouter {
    var section: LibrarySection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.sectionKey) }
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
    /// Clear Data… or Uninstall… from an app's menu (AppTileInteraction.swift), to confirm.
    var confirmation: AppConfirmation?

    static let sectionKey = "AvoLibrarySection"
    static let gamesListKey = "AvoLibraryGamesAsList"

    init() {
        section = UserDefaults.standard.string(forKey: Self.sectionKey).flatMap(LibrarySection.init(rawValue:)) ?? .home
        gamesAsList = UserDefaults.standard.bool(forKey: Self.gamesListKey)
    }

    func show(_ section: LibrarySection) {
        page = nil
        if self.section != section { search = "" }
        self.section = section
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
        .ignoresSafeArea()
        .hazeTracksPointer(pointer)
        // The pointer effects rest while the window is in the background.
        .onChange(of: appearsActive && !reduceMotion, initial: true) { _, live in pointer.setLive(live) }
        .onDisappear { pointer.detach() }
        .foregroundStyle(Haze.text)
        .tint(Haze.accent)
        .preferredColorScheme(.dark)
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
        .onChange(of: model.apps.map(\.package)) { _, packages in
            // An app uninstalled while its page showed.
            if let page = router.page, !packages.contains(page) { router.page = nil }
        }
        .sheet(item: $model.pendingInstall) { _ in
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
        .background { LibraryWindowAccessor(pillHidden: router.page != nil, pointer: pointer) }
    }

    /// Spec §3: dragging a package onto the window installs it.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in model.prepareInstall(url) }
        }
        return true
    }
}

/// The content beside the sidebar: the top bar (search, filter, Install App)
/// over Home, Games and Apps; Notifications has its own header.
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
                case .home, .games, .apps:
                    VStack(alignment: .leading, spacing: 26) {
                        LibraryTopBar()
                            .padding(.horizontal, 34)
                        ZStack(alignment: .topLeading) {
                            switch router.section {
                            case .games: GamesCollection().transition(arrival)
                            case .apps: AppsCollection().transition(arrival)
                            default:
                                if router.search.isEmpty {
                                    LibraryHome().transition(arrival)
                                } else {
                                    SearchResults().transition(arrival)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

/// Search, the All / Games / Apps switch and Install App.
private struct LibraryTopBar: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        HStack(spacing: 14) {
            HazeSearchField(text: $router.search, prompt: "Search apps and games")
                .frame(maxWidth: 368)
            HazeSegmented(options: [(LibrarySection.home, Text("All")), (.games, Text("Games")), (.apps, Text("Apps"))],
                          selection: Binding(get: { router.section }, set: { router.show($0) }))
                .fixedSize()
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
                    Button("Retry") { model.connect() }
                }
            }
            LibrarySetupBanner()
            // Android's data is on a drive that is not connected (StorageLocationViews.swift).
            StorageProblemBanner()
            if model.screenLock != nil, model.daemonState == .connected {
                HazeBanner(symbol: "lock.fill", tint: Haze.warning,
                           text: "Android is locked by its screen lock. Your apps open after you unlock it.") {
                    Button("Unlock…") { model.unlockSheetShown = true }
                }
            }
            if model.pendingRestart {
                HazeBanner(symbol: "arrow.clockwise.circle", tint: Haze.accent,
                           text: "Some changes apply after Android restarts. Your apps and data are kept.") {
                    Button("Restart Android") { model.restartVM() }
                        .disabled(model.googleAppsChangingAndroid)
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
    }

    private var bannerState: [Bool] {
        [model.daemonState == .connected, model.daemonState == .connecting, model.daemonState == .needsApproval,
         model.screenLock != nil, model.pendingRestart, images.needsImage && !assistant.isPresented,
         model.status.renderer?.reason == .failed && model.config?.rendererMode != .software]
    }

    private var hasBanner: Bool {
        model.daemonState != .connected || (model.screenLock != nil && model.daemonState == .connected) || model.pendingRestart
            || (images.needsImage && !assistant.isPresented)
            || (model.status.renderer?.reason == .failed && model.config?.rendererMode != .software)
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
    /// An app's page covers the window: the pill steps aside.
    let pillHidden: Bool
    let pointer: HazePointer

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        let model = self.model
        let openWindow = context.environment.openWindow
        let hidden = pillHidden
        let pointer = self.pointer
        view.onWindow = { window in
            pointer.attach(to: window)
            window.backgroundColor = NSColor(Haze.windowBase)
            window.appearance = NSAppearance(named: .darkAqua)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.minSize = NSSize(width: 980, height: 640)
            StatusPillController.attach(to: window, model: model) { openWindow(id: SettingsWindow.id) }
            StatusPillController.setHidden(hidden, for: window)
        }
        return view
    }

    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        StatusPillController.setHidden(pillHidden, for: nsView.window)
    }
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
