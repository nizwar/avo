import AppKit
import AvoKeymap
import AvoKit
import CoreText
import SwiftUI

// Quick Settings: the title bar's slider button opens, under itself, the
// settings of this window whose effect shows at once, in the Library's haze
// look: Android's volume, this app's graphics (as on its page in the Control Panel) with
// Android's frame rate cap, the performance HUD, the app bar style, the key
// mapping, scrolling and Translate Screen. What needs Android to restart or applies elsewhere
// (CPU, memory, renderer, device identity, Android version) stays in the
// Control Panel, a click away at the bottom (All Settings for the app).
// Last but that, where Android's GPS says it is, with the Location panel a
// click away. A click outside the overlay or Esc closes it.

// MARK: - What it shows and changes

/// The overlay's settings as its window has them now.
struct QuickSettingsState: Equatable {
    /// The app's name, for All Settings.
    var appName = ""
    struct KeyMapping: Equatable {
        var gameMode: Bool
        var hintsVisible: Bool
        var hintsOpacity: Double
    }

    /// The device profile chosen in the Control Panel, when it has a screen.
    struct Phone: Equatable {
        var name: String
        var display: DeviceProfile.Display
    }

    var graphics = ResolvedGraphics(settings: .appsDefault, profile: .apps, reason: .none, changes: .init())
    /// The screen "Phone" gives Android; nil for Avo's own identity, which has none.
    var phone: Phone?
    /// The app has graphics of its own (Use Default Graphics Settings applies).
    var hasOwnGraphics = false
    /// Render scales below this one cannot be used on the window's screen.
    var lowestRenderScale = GraphicsSettings.renderScaleRange.lowerBound
    var fpsLimit = 60
    /// The caps to offer (FrameRates.choices).
    var fpsChoices = VMConfig.fpsChoices
    /// What the Mac's screens make of the cap, when none shows it evenly (FrameRates.screenNote).
    var fpsNote: String?
    var hudLevel = PerformanceHUDLevel.off
    /// The app's windows' style: their own, else the Control Panel's.
    var appBarStyle = AppBarStyle.standard
    /// nil while the app has no key mapping.
    var keyMapping: KeyMapping?
    /// The key mapping editor can open (the display has).
    var canEditKeyMapping = false
    var scrollMode = ScrollMode.automatic
    var translating = false
    /// Translate Screen reads the display's frames: none before it opens.
    var canTranslate = false
    /// ScreenTranslationSettings.target: nil follows the Mac's language.
    var translationTarget: String?
}

/// The window the overlay belongs to (AndroidWindowController).
@MainActor
protocol QuickSettingsTarget: AnyObject {
    var quickSettingsState: QuickSettingsState { get }
    /// Apps or Games for this app, keeping what it changed on top.
    func quickSettingsChooseProfile(_ profile: GraphicsProfile)
    /// Saved as this app's own: only what differs from its profile.
    func quickSettingsChangeGraphics(_ change: (inout GraphicsSettings) -> Void)
    func quickSettingsUseDefaultGraphics()
    /// Shows a sharpness while its slider is dragged, before it is saved;
    /// nil shows the saved one again.
    func quickSettingsPreviewSharpness(_ sharpness: Int?)
    /// Android's, for every app.
    func quickSettingsSetFrameRateLimit(_ fps: Int)
    /// This window's, as ⌥⌘P.
    func quickSettingsSetHUDLevel(_ level: PerformanceHUDLevel)
    /// This app's own, as Phone Style in its windows' menus; the Control
    /// Panel's one leaves it following the Control Panel.
    func quickSettingsSetAppBarStyle(_ style: AppBarStyle)
    func quickSettingsSetGameMode(_ on: Bool)
    func quickSettingsSetTranslating(_ on: Bool)
    /// Android's media volume, every app's; nil while Android is not running.
    func quickSettingsAndroidVolume() async -> AndroidVolume?
    /// Sets it; the volume Android has afterwards.
    func quickSettingsSetAndroidVolume(_ level: Int) async -> AndroidVolume?
    /// The app's page in the Control Panel.
    func quickSettingsOpenAppSettings()
    /// The key mapping editor, over the game (⇧⌘K).
    func quickSettingsEditKeyMapping()
}

@MainActor
final class QuickSettingsModel: ObservableObject {
    @Published private(set) var state = QuickSettingsState()
    /// Translate Into's languages, each once, sorted by name.
    @Published private(set) var languages: [ScreenTranslationController.TargetLanguage] = []
    /// The chosen one as Translate Into lists it; nil for the Mac's language.
    @Published private(set) var chosenLanguage: String?
    /// "English", for "System Language (English)".
    @Published private(set) var systemLanguage = ""
    /// The overlay never grows taller than its screen.
    @Published var maxHeight: CGFloat = 640
    /// Android's media volume while the overlay shows; nil while Android is not running.
    @Published private(set) var volume: AndroidVolume?
    weak var target: (any QuickSettingsTarget)?
    /// The level the slider asked for while a change was on its way: the latest wins.
    private var volumeWanted: Int?
    private var volumeSending = false

    func refresh() {
        guard let new = target?.quickSettingsState, new != state else { return }
        let targetChanged = new.translationTarget != state.translationTarget
        state = new
        if targetChanged { chosenLanguage = TranslationLanguages.chosenMenuIdentifier }
    }

    /// Asks Android its volume as the overlay opens.
    func loadVolume() {
        Task { [weak self] in
            guard let volume = await self?.target?.quickSettingsAndroidVolume() else { return }
            // Not over a level the slider is sending.
            if self?.volumeWanted == nil, self?.volumeSending == false { self?.volume = volume }
        }
    }

    /// The slider moved: Android follows, one change at a time, the latest
    /// level last.
    func setVolume(_ level: Int) {
        guard var shown = volume, shown.level != level else { return }
        shown.level = level
        volume = shown
        volumeWanted = level
        guard !volumeSending else { return }
        volumeSending = true
        Task { [weak self] in await self?.sendVolume() }
    }

    private func sendVolume() async {
        while let level = volumeWanted {
            volumeWanted = nil
            let result = await target?.quickSettingsSetAndroidVolume(level)
            if volumeWanted == nil, let result { volume = result }
        }
        volumeSending = false
    }

    /// The languages known now, then every one once macOS has said.
    func loadLanguages() {
        showLanguages()
        Task { [weak self] in
            _ = await TranslationLanguages.supported()
            self?.showLanguages()
        }
    }

    private func showLanguages() {
        let menu = TranslationLanguages.menu
        if menu != languages { languages = menu }
        chosenLanguage = TranslationLanguages.chosenMenuIdentifier
        systemLanguage = TranslationLanguages.name(of: TranslationLanguages.systemLanguage)
    }

    /// A change in the window, then what it did.
    func change(_ body: (any QuickSettingsTarget) -> Void) {
        guard let target else { return }
        body(target)
        refresh()
    }

    func changeGraphics(_ change: (inout GraphicsSettings) -> Void) {
        self.change { $0.quickSettingsChangeGraphics(change) }
    }

    // The Window Host's own settings, the same in every window of the app.

    func setHintsVisible(_ on: Bool) {
        KeymapHints.visible = on
        refresh()
    }

    func setHintsOpacity(_ opacity: Double) {
        KeymapHints.opacity = opacity
        refresh()
    }

    func setScrollMode(_ mode: ScrollMode) {
        WheelScrollController.settings.setAppMode(mode)
        refresh()
    }

    /// Every app's (Translate Into).
    func setTranslationTarget(_ identifier: String?) {
        ScreenTranslationSettings.target = identifier
        refresh()
    }
}

// MARK: - The button and its overlay

/// The title bar's Quick Settings button and the overlay it opens under
/// itself: a transient popover, so a click outside it or Esc closes it.
@MainActor
final class QuickSettingsOverlay: NSObject, NSPopoverDelegate {
    static var title: String { String(localized: "Quick Settings", bundle: .windowHost) }

    let button = TitlebarButton(symbol: "slider.horizontal.3", label: QuickSettingsOverlay.title, action: nil)
    private let model = QuickSettingsModel()
    private var popover: NSPopover?
    private var observers: [any NSObjectProtocol] = []
    private var keyMonitor: Any?
    /// When it last closed: the click on the button that closed it must not open it again.
    private var closedAt = -Double.infinity

    init(target: any QuickSettingsTarget) {
        super.init()
        model.target = target
        button.target = self
        button.action = #selector(toggle)
    }

    var isShown: Bool { popover?.isShown == true }

    @objc func toggle() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else if ProcessInfo.processInfo.systemUptime - closedAt > 0.3 {
            show()
        }
    }

    /// Something it shows changed in the window (the daemon's configuration, ⌘G, ⌥⌘P).
    func refresh() {
        if isShown { model.refresh() }
    }

    private func show() {
        guard let window = button.window else { return }
        model.refresh()
        model.loadLanguages()
        model.loadVolume()
        if let screen = window.screen { model.maxHeight = max(320, screen.visibleFrame.height - 140) }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        popover.hasFullSizeContent = true
        let host = NSHostingController(rootView: QuickSettingsView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.delegate = self
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: button.isFlipped ? .maxY : .minY)
        // Esc and the keyboard are the overlay's now, never Android's.
        host.view.window?.makeKey()
        showOpen(true)
        for name in [KeymapHints.changed, ScreenTranslationSettings.changed] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.refresh() }
            })
        }
        // A choice's menu (QuickMenu) takes the keyboard while it shows: the
        // overlay stays open meanwhile, and has the keyboard again after.
        for (name, behavior) in [(HazeMenuPresenter.willShowNotification, NSPopover.Behavior.applicationDefined),
                                 (HazeMenuPresenter.didCloseNotification, .transient)] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.popover?.behavior = behavior }
            })
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.escape(event) == true ? nil : event
        }
    }

    private func escape(_ event: NSEvent) -> Bool {
        guard event.keyCode == 53, // kVK_Escape
              let popover, popover.isShown, event.window === popover.contentViewController?.view.window else { return false }
        popover.performClose(nil)
        return true
    }

    func popoverDidClose(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        popover = nil
        closedAt = ProcessInfo.processInfo.systemUptime
        // A sharpness still being dragged goes back to the saved one.
        model.target?.quickSettingsPreviewSharpness(nil)
        showOpen(false)
    }

    private func showOpen(_ open: Bool) {
        button.state = open ? .on : .off
        button.contentTintColor = open ? .controlAccentColor : nil
    }
}

// MARK: - The overlay

private func L(_ key: String.LocalizationValue) -> String { String(localized: key, bundle: .windowHost) }

struct QuickSettingsView: View {
    @ObservedObject var model: QuickSettingsModel

    var body: some View {
        let state = model.state
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: QuickSettingsOverlay.title)
                        .font(QuickHaze.hubot(15, 700))
                        .foregroundStyle(QuickHaze.text)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: L("Changes apply right away."))
                        .font(QuickHaze.mona(11.5))
                        .foregroundStyle(QuickHaze.textTertiary)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
                if let volume = model.volume { soundCard(volume) }
                QuickGraphicsCard(model: model)
                QuickCard(title: L("Performance HUD"), scope: L("This window")) {
                    QuickSegmented(label: L("Performance HUD"),
                                   options: [(PerformanceHUDLevel.off, L("Off")), (.fps, L("FPS Only")), (.detailed, L("Detailed"))],
                                   selection: state.hudLevel, fill: true) { level in
                        model.change { $0.quickSettingsSetHUDLevel(level) }
                    }
                }
                QuickCard(title: L("App bar style"), scope: L("This app")) {
                    QuickSegmented(label: L("App bar style"), options: [(AppBarStyle.standard, L("Standard")), (.phone, L("Phone style"))],
                                   selection: state.appBarStyle, fill: true, help: { style in
                                       style == .phone
                                           ? L("The app’s screen alone, with a phone’s rounded corners. Its title bar shows when the pointer leaves the screen at the top.")
                                           : L("A Mac window, its title bar always shown.")
                                   }) { style in
                        model.change { $0.quickSettingsSetAppBarStyle(style) }
                    }
                }
                if let keys = state.keyMapping {
                    keyMappingCard(keys)
                } else if state.canEditKeyMapping {
                    // Without one, the way to make one.
                    QuickCard(title: L("Game controls"), scope: L("This app")) {
                        QuickRow(label: L("No key mapping yet"),
                                 help: L("Put keys, mouse buttons and the controller on the game’s buttons, then turn on Game Mode (⌘G) to play with them.")) {
                            LocationButton(title: L("Create Key Mapping…"), symbol: "keyboard", style: .secondary) {
                                model.change { $0.quickSettingsEditKeyMapping() }
                            }
                        }
                    }
                }
                QuickCard(title: L("Scrolling"), scope: L("This app")) {
                    QuickSegmented(label: L("Scrolling"), options: ScrollMode.allCases.map { ($0, ScrollModeMenu.name(of: $0)) },
                                   selection: state.scrollMode, fill: true, help: { ScrollModeMenu.explanation(of: $0) }) { mode in
                        model.setScrollMode(mode)
                    }
                }
                translationCard(state)
                // Android's GPS: this Mac, a place or a route (LocationPanel.swift).
                QuickLocationCard()
                // What applies elsewhere or needs Android to restart: the app's page.
                LocationButton(title: L("All Settings for \(state.appName)…"), symbol: "gearshape", style: .secondary) {
                    model.change { $0.quickSettingsOpenAppSettings() }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .scrollIndicators(.automatic)
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 330)
        .frame(maxHeight: model.maxHeight)
        .background { QuickHaze.background.ignoresSafeArea() }
        .environment(\.colorScheme, .dark)
    }

    /// Android's media volume, under the Mac's volume.
    private func soundCard(_ volume: AndroidVolume) -> some View {
        let percent = Text(Double(volume.level) / Double(max(volume.maximum, 1)), format: .percent.precision(.fractionLength(0)))
        return QuickCard(title: L("Sound"), scope: L("Every app")) {
            QuickSliderRow(label: L("Volume"), value: percent,
                           help: L("Android plays under your Mac’s volume: at 100%, the Mac’s volume alone sets how loud it is.")) {
                QuickSlider(label: L("Volume"), value: Binding(get: { Double(volume.level) }, set: { model.setVolume(Int($0.rounded())) }),
                            range: 0...Double(volume.maximum), step: 1, valueText: percent)
            }
        }
    }

    private func keyMappingCard(_ keys: QuickSettingsState.KeyMapping) -> some View {
        let percent = Text(keys.hintsOpacity, format: .percent.precision(.fractionLength(0)))
        return QuickCard(title: L("Game controls"), scope: L("This app")) {
            QuickToggle(label: L("Game Mode"), shortcut: "⌘G", caption: L("Keys and clicks become touches"), isOn: keys.gameMode) { on in
                model.change { $0.quickSettingsSetGameMode(on) }
            }
            VStack(alignment: .leading, spacing: 9) {
                QuickToggle(label: L("Show keys on game"), isOn: keys.hintsVisible) { model.setHintsVisible($0) }
                QuickSliderRow(label: L("Key visibility"), value: percent) {
                    QuickSlider(label: L("Key visibility"), value: Binding(get: { keys.hintsOpacity }, set: { model.setHintsOpacity($0) }),
                                range: KeymapHints.opacityRange, step: 0.05, valueText: percent)
                }
                .disabled(!keys.hintsVisible)
                .opacity(keys.hintsVisible ? 1 : 0.5)
            }
        }
    }

    /// "System Language (English)", then Translate Into's languages.
    private var targetOptions: [QuickMenuOption<String?>] {
        let system = QuickMenuOption<String?>(value: nil, title: L("System Language (\(model.systemLanguage))"))
        return [system] + model.languages.map { QuickMenuOption<String?>(value: $0.identifier, title: $0.name) }
    }

    /// The language translated into, chosen or the Mac's.
    private var targetTitle: String {
        let chosen = model.chosenLanguage.flatMap { id in model.languages.first { $0.identifier == id } }
        return chosen?.name ?? model.systemLanguage
    }

    private func translationCard(_ state: QuickSettingsState) -> some View {
        QuickCard(title: L("Translation"), scope: L("This window")) {
            QuickToggle(label: L("Translate screen"), shortcut: "⇧⌘T", isOn: state.translating) { on in
                model.change { $0.quickSettingsSetTranslating(on) }
            }
            .disabled(!state.canTranslate && !state.translating)
            .opacity(state.canTranslate || state.translating ? 1 : 0.5)
            QuickRow(label: L("Translate into"), caption: L("Every app"), inline: true) {
                QuickMenu(label: L("Translate into"), title: targetTitle, options: targetOptions,
                          selection: model.chosenLanguage) { model.setTranslationTarget($0) }
            }
        }
    }
}

/// This app's graphics, as on its page in the Control Panel, and Android's frame rate cap.
private struct QuickGraphicsCard: View {
    @ObservedObject var model: QuickSettingsModel
    /// The sharpness while its slider is dragged (saved when let go).
    @State private var sharpnessDraft: Double?

    var body: some View {
        let state = model.state
        let settings = state.graphics.settings
        QuickCard(title: L("Graphics"), scope: L("This app")) {
            QuickRow(label: L("Preset"), help: L("Apps: Android takes the window’s size, sharp for reading. Games: a fixed 720p landscape screen that runs faster. What you change below is kept on top.")) {
                QuickSegmented(label: L("Preset"), options: [(GraphicsProfile.apps, L("Apps")), (.games, L("Games"))],
                               selection: state.graphics.profile, fill: true) { choice in
                    model.change { $0.quickSettingsChooseProfile(choice) }
                }
            }
            screenRows(settings, state: state)
            VStack(alignment: .leading, spacing: 9) {
                QuickToggle(label: L("Sharp upscaling"), caption: L("Apple’s MetalFX keeps edges and text sharp when the picture is enlarged."),
                            isOn: settings.filter == .metalFXSpatial) { on in
                    model.changeGraphics { $0.filter = on ? .metalFXSpatial : .bilinear }
                }
                sharpness(settings)
            }
            QuickRow(label: L("Smooth edges"), help: L("Fast smooths jagged edges in Avo (FXAA) and costs almost nothing. High and Ultra have Android draw 2 or 4 times the pixels and shrink them: the smoothest, but much more work for the GPU.")) {
                QuickSegmented(label: L("Smooth edges"), options: GraphicsSettings.AntiAliasing.allCases.map { ($0, GraphicsMenu.shortTitle($0)) },
                               selection: settings.antiAliasing, fill: true) { value in
                    model.changeGraphics { $0.antiAliasing = value }
                }
            }
            QuickRow(label: L("Max FPS"), caption: L("Every app"), help: state.fpsNote) {
                // 90 and 120 always, and a screen's own rate (75 Hz); 30 saves power.
                QuickSegmented(label: L("Max FPS"),
                               options: state.fpsChoices.map { ($0, "\($0)") },
                               selection: state.fpsLimit, fill: true) { fps in
                    model.change { $0.quickSettingsSetFrameRateLimit(fps) }
                }
            }
            if state.hasOwnGraphics {
                Button {
                    model.change { $0.quickSettingsUseDefaultGraphics() }
                } label: {
                    Text(verbatim: L("Use Default Graphics Settings"))
                        .font(QuickHaze.mona(12.5, 600))
                        .foregroundStyle(QuickHaze.accent)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// How Android's screen is sized, with that mode's own row and its shape;
    /// then its orientation.
    @ViewBuilder private func screenRows(_ settings: GraphicsSettings, state: QuickSettingsState) -> some View {
        let phone = state.phone
        let mode = settings.effectiveMode(device: phone?.display)
        VStack(alignment: .leading, spacing: 9) {
            screenSize(settings, mode: mode, phone: phone)
            switch mode {
            case .followWindow: renderScaleRow(settings, lowest: state.lowestRenderScale)
            case .fixed: resolutionRow(settings)
            case .deviceProfile: EmptyView()
            }
            aspectRatioRow(settings, mode: mode, phone: phone)
        }
        QuickRow(label: L("Orientation")) {
            QuickSegmented(label: L("Orientation"), options: [(VMConfig.Orientation.portrait, L("Portrait")), (.landscape, L("Landscape"))],
                           selection: settings.orientation, fill: true) { orientation in
                model.changeGraphics { $0.orientation = orientation }
            }
        }
    }

    private func screenSize(_ settings: GraphicsSettings, mode: GraphicsSettings.Mode, phone: QuickSettingsState.Phone?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            QuickRow(label: L("Screen size"), help: L("How big Android’s screen is: the window’s size, one fixed resolution, or the size of the phone chosen in Avo’s Settings.")) {
                QuickSegmented(label: L("Screen size"),
                               options: [(GraphicsSettings.Mode.followWindow, L("Window")), (.fixed, L("Fixed")), (.deviceProfile, L("Phone"))],
                               selection: mode, fill: true, help: { choice in
                    switch choice {
                    case .followWindow: L("Android renders at the window’s size.")
                    case .fixed: L("Android keeps one resolution, scaled to the window.")
                    case .deviceProfile: phone == nil ? L("Choose a phone in Avo’s Settings › Privacy & Security › Device profile.")
                                                      : L("Android gets the phone’s screen, so apps lay out as on the phone.")
                    }
                }, enabled: { $0 != .deviceProfile || phone != nil }) { choice in
                    model.changeGraphics { $0.mode = choice }
                }
            }
            if let phone, mode == .deviceProfile {
                let display = phone.display
                QuickCaption("\(phone.name) · \(String(display.width)) × \(String(display.height)) · \(String(display.dpi)) dpi")
            } else if settings.mode == .deviceProfile {
                QuickCaption(L("No phone is chosen in Avo’s Settings › Privacy & Security, so Android follows the window."))
            }
        }
    }

    private func resolutionRow(_ settings: GraphicsSettings) -> some View {
        let presets = GraphicsSettings.resolutionPresets
        // A custom resolution (the View menu's Custom…, the Control Panel) is listed too.
        let values = presets.contains(settings.shortSide) ? presets : (presets + [settings.shortSide]).sorted()
        let options = values.map { QuickMenuOption(value: $0, title: GraphicsSettings.resolutionName($0)) }
        return QuickRow(label: L("Resolution"), inline: true) {
            QuickMenu(label: L("Resolution"), title: GraphicsSettings.resolutionName(settings.shortSide), options: options,
                      selection: settings.shortSide) { pixels in
                model.changeGraphics {
                    $0.mode = .fixed
                    $0.shortSide = pixels
                }
            }
        }
    }

    /// The current mode's shape; the phone's screen has the phone's.
    @ViewBuilder private func aspectRatioRow(_ settings: GraphicsSettings, mode: GraphicsSettings.Mode,
                                             phone: QuickSettingsState.Phone?) -> some View {
        if mode == .deviceProfile, let phone {
            QuickRow(label: L("Aspect ratio"), inline: true) {
                QuickValue(Text(verbatim: phone.display.ratioName))
            }
        } else {
            let current = settings.aspectRatio(for: mode)
            let title = { (ratio: GraphicsSettings.AspectRatio) in ratio == .matchWindow ? L("Match window") : ratio.rawValue }
            QuickRow(label: L("Aspect ratio"), inline: true) {
                QuickMenu(label: L("Aspect ratio"), title: title(current),
                          options: GraphicsSettings.AspectRatio.allCases.map { QuickMenuOption(value: $0, title: title($0)) },
                          selection: current) { ratio in
                    model.changeGraphics { $0.setAspectRatio(ratio, for: mode) }
                }
            }
        }
    }

    private func renderScaleRow(_ settings: GraphicsSettings, lowest: Int) -> some View {
        let options = GraphicsSettings.RenderScalePreset.allCases.map { preset in
            let title = GraphicsMenu.title(preset)
            // Android's density cannot go below 120 dpi, which sets a floor on this screen.
            return preset.rawValue < lowest ? QuickMenuOption(value: preset.rawValue, title: L("\(title) — not on this display"), enabled: false)
                                            : QuickMenuOption(value: preset.rawValue, title: title)
        }
        let title = GraphicsSettings.RenderScalePreset(rawValue: settings.renderScale).map(GraphicsMenu.title) ?? "\(settings.renderScale)%"
        return QuickRow(label: L("Render scale"), inline: true) {
            QuickMenu(label: L("Render scale"), title: title, options: options, selection: settings.renderScale) { percent in
                model.changeGraphics {
                    $0.mode = .followWindow
                    $0.renderScale = percent
                }
            }
        }
    }

    private func sharpness(_ settings: GraphicsSettings) -> some View {
        let shown = Int((sharpnessDraft ?? Double(settings.sharpness)).rounded())
        let value = shown == 0 ? Text(verbatim: L("Off")) : Text(Double(shown) / 100, format: .percent)
        let enabled = settings.filter != .nearest
        let range = Double(GraphicsSettings.sharpnessRange.lowerBound)...Double(GraphicsSettings.sharpnessRange.upperBound)
        return QuickSliderRow(label: L("Sharpness"), value: value) {
            QuickSlider(label: L("Sharpness"), value: Binding(get: { sharpnessDraft ?? Double(settings.sharpness) }, set: { newValue in
                if sharpnessDraft == nil {
                    // A key or VoiceOver step: saved at once.
                    commitSharpness(Int(newValue.rounded()), saved: settings.sharpness)
                } else {
                    sharpnessDraft = newValue
                    model.target?.quickSettingsPreviewSharpness(Int(newValue.rounded()))
                }
            }), range: range, step: Double(GraphicsSettings.sharpnessStep), valueText: value) { editing in
                if editing {
                    sharpnessDraft = Double(settings.sharpness)
                } else if let draft = sharpnessDraft {
                    sharpnessDraft = nil
                    commitSharpness(Int(draft.rounded()), saved: settings.sharpness)
                }
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func commitSharpness(_ value: Int, saved: Int) {
        guard value != saved else {
            model.target?.quickSettingsPreviewSharpness(nil)
            return
        }
        model.changeGraphics { $0.sharpness = value }
    }
}

// MARK: - The haze look, in small

/// The Control Panel's haze (HazeTheme.swift in Avo.app), the few colours,
/// type and controls the overlay uses (and the Location panel, LocationPanel.swift,
/// and the widget panels, WidgetPanels.swift, through the AppKit ones).
@MainActor
enum QuickHaze {
    static func rgb(_ value: UInt32, _ alpha: Double = 1) -> Color {
        Color(.sRGB, red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255,
              blue: Double(value & 0xFF) / 255, opacity: alpha)
    }

    /// The same colours for AppKit views.
    nonisolated static func nsRGB(_ value: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
    }

    static let base = rgb(0x0A1108)
    static let card = rgb(0xF3F1E8, 0.045)
    static let inset = Color.black.opacity(0.28)
    static let text = rgb(0xF3F1E8)
    static let textSecondary = rgb(0xC5CDB9)
    static let textTertiary = rgb(0x9AA58E)
    static let sectionLabel = rgb(0x8F9B84)
    static let accent = rgb(0xD8E8A7)
    static let onAccent = rgb(0x15210E)
    static let accentText = rgb(0xEEF5D6)
    static let segmentSelection = rgb(0xD8E8A7, 0.2)
    /// A menu's lit item (HazeMenu.swift), and a destructive one's.
    static let selection = rgb(0xD8E8A7, 0.14)
    static let danger = rgb(0xF3B8A2)
    static let dangerFill = rgb(0xF39A7C, 0.14)

    /// Near black with a breath of Avo green top right and bottom left.
    static var background: some View {
        ZStack {
            base
            EllipticalGradient(colors: [rgb(0xD8E8A7, 0.2), rgb(0xD8E8A7, 0)], center: UnitPoint(x: 0.92, y: -0.04),
                               startRadiusFraction: 0, endRadiusFraction: 0.75)
            EllipticalGradient(colors: [rgb(0xBCDC8F, 0.09), rgb(0xBCDC8F, 0)], center: UnitPoint(x: 0.06, y: 1.04),
                               startRadiusFraction: 0, endRadiusFraction: 0.7)
        }
    }

    // Hubot Sans and Mona Sans from Avo.app (Fonts/), else the system font.

    private enum Family: String {
        case hubot = "hubot-sans"
        case mona = "mona-sans"
    }

    private static var bases: [Family: CTFontDescriptor?] = [:]
    private static var fonts: [String: Font] = [:]

    static func hubot(_ size: CGFloat, _ weight: CGFloat = 700) -> Font { font(.hubot, size, weight) }
    static func mona(_ size: CGFloat, _ weight: CGFloat = 400) -> Font { font(.mona, size, weight) }

    /// Mona Sans for AppKit views.
    static func monaFont(_ size: CGFloat, _ weight: CGFloat = 400) -> NSFont {
        ctFont(.mona, size, weight).map { $0 as NSFont }
            ?? .systemFont(ofSize: size, weight: weight >= 650 ? .bold : weight >= 550 ? .semibold : .regular)
    }

    private static func font(_ family: Family, _ size: CGFloat, _ weight: CGFloat) -> Font {
        let key = "\(family.rawValue)-\(size)-\(weight)"
        if let font = fonts[key] { return font }
        let font: Font = ctFont(family, size, weight).map { Font($0) }
            ?? .system(size: size, weight: weight >= 650 ? .bold : weight >= 550 ? .semibold : .regular)
        fonts[key] = font
        return font
    }

    private static func ctFont(_ family: Family, _ size: CGFloat, _ weight: CGFloat) -> CTFont? {
        guard let base = base(family) else { return nil }
        var descriptor = CTFontDescriptorCreateCopyWithVariation(base, tag("wght") as CFNumber, weight)
        descriptor = CTFontDescriptorCreateCopyWithVariation(descriptor, tag("wdth") as CFNumber, 100)
        return CTFontCreateWithFontDescriptor(descriptor, size, nil)
    }

    private static func base(_ family: Family) -> CTFontDescriptor? {
        if let known = bases[family] { return known }
        // The framework is Avo.app/Contents/Frameworks/AvoWindowHost.framework.
        let resources = Bundle.windowHost.bundleURL.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Resources")
        let candidates = [resources, AndroidWindowController.hostApplication?.appending(path: "Contents/Resources")].compactMap { $0 }
        let descriptor = candidates.lazy
            .compactMap { try? Data(contentsOf: $0.appending(path: "\(family.rawValue).woff2")) }
            .compactMap { (CTFontManagerCreateFontDescriptorsFromData($0 as CFData) as? [CTFontDescriptor])?.first }
            .first
        bases[family] = .some(descriptor)
        return descriptor
    }

    private static func tag(_ name: String) -> Int {
        name.utf8.reduce(0) { $0 << 8 | Int($1) }
    }
}

/// A card: its title, whom it applies to, and its settings.
struct QuickCard<Content: View>: View {
    let title: String
    let scope: String
    /// A line between its settings, so each one reads as its own.
    var separated = true
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(QuickHaze.hubot(13.5, 650))
                    .foregroundStyle(QuickHaze.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                Text(verbatim: scope)
                    .font(QuickHaze.mona(11, 500))
                    .foregroundStyle(QuickHaze.sectionLabel)
            }
            if separated {
                QuickRows { content }
            } else {
                content
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(QuickHaze.card, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

/// Settings one under the other, a line between each two: each view of
/// `content` is one (a VStack keeps the ones that belong together).
struct QuickRows<Content: View>: View {
    var spacing: CGFloat = 9
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows) { row in
                    if row.id != rows.first?.id { QuickSeparator().padding(.vertical, spacing) }
                    row
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The line between two settings.
struct QuickSeparator: View {
    var body: some View {
        Rectangle()
            .fill(QuickHaze.text.opacity(0.08))
            .frame(height: 1)
            .accessibilityHidden(true)
    }
}

struct QuickText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(QuickHaze.mona(13.5)).foregroundStyle(QuickHaze.text)
    }
}

struct QuickCaption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(QuickHaze.mona(11.5))
            .foregroundStyle(QuickHaze.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A setting's value at the end of its row ("35%").
struct QuickValue: View {
    let text: Text
    init(_ text: Text) { self.text = text }

    var body: some View {
        text.font(QuickHaze.mona(12.5)).foregroundStyle(QuickHaze.textTertiary).monospacedDigit()
    }
}

/// Whom a setting applies to ("Every app"), on the right of its name.
struct QuickScope: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text).font(QuickHaze.mona(11, 500)).foregroundStyle(QuickHaze.sectionLabel).lineLimit(1)
    }
}

/// A setting's (?): what it does, under the pointer, and below its name
/// while clicked.
struct QuickHelpButton: View {
    let help: String
    @Binding var shown: Bool

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { shown.toggle() }
        } label: {
            Image(systemName: shown ? "questionmark.circle.fill" : "questionmark.circle")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(shown ? QuickHaze.accent : QuickHaze.textTertiary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(verbatim: L("More about this")))
        .accessibilityHint(Text(verbatim: help))
    }
}

/// A setting's name, its key in the window ("⌘G"), and a (?) when there is
/// more to say: under the pointer, and below the name once it is clicked.
struct QuickLabel: View {
    let title: String
    var shortcut: String?
    var help: String?
    var font = QuickHaze.mona(13.5)
    var color = QuickHaze.text
    @State private var showsHelp = false

    init(_ title: String, shortcut: String? = nil, help: String? = nil, font: Font = QuickHaze.mona(13.5), color: Color = QuickHaze.text) {
        self.title = title
        self.shortcut = shortcut
        self.help = help
        self.font = font
        self.color = color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(verbatim: title).font(font).foregroundStyle(color)
                if let shortcut {
                    Text(verbatim: shortcut).font(QuickHaze.mona(11.5)).foregroundStyle(QuickHaze.textTertiary)
                }
                if let help { QuickHelpButton(help: help, shown: $showsHelp) }
            }
            if showsHelp, let help { QuickCaption(help) }
        }
    }
}

/// A setting: its name (and its ?) with whom it applies to on the right,
/// and its control under them, as wide as the card; `inline`, a small
/// control (a menu, a value) on the right of the name instead.
struct QuickRow<Control: View>: View {
    let label: String
    /// Whom it applies to ("Every app").
    var caption: String?
    var help: String?
    var inline = false
    @ViewBuilder let control: Control

    var body: some View {
        if inline {
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    QuickLabel(label, help: help)
                    if let caption { QuickScope(caption) }
                }
                Spacer(minLength: 6)
                control
            }
        } else {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    QuickLabel(label, help: help)
                    Spacer(minLength: 6)
                    if let caption { QuickScope(caption) }
                }
                control
            }
        }
    }
}

/// A setting with a slider: its name (and its ?) and its value on one line,
/// the slider under them.
struct QuickSliderRow<Slider: View>: View {
    let label: String
    let value: Text
    var help: String?
    @ViewBuilder let slider: Slider

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                QuickLabel(label, help: help)
                Spacer(minLength: 6)
                QuickValue(value)
            }
            slider.frame(maxWidth: .infinity)
        }
    }
}

/// The haze checkbox (an Avo green square with a dark check) at the end of
/// its row; a click on the name sets it too.
struct QuickToggle: View {
    let label: String
    /// Its key in the window ("⌘G"), after the label.
    var shortcut: String?
    /// What it does, behind its (?).
    var caption: String?
    let isOn: Bool
    let set: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            QuickLabel(label, shortcut: shortcut, help: caption)
                .contentShape(Rectangle())
                .onTapGesture { set(!isOn) }
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Button {
                set(!isOn)
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(isOn ? QuickHaze.accent : Color.white.opacity(0.92))
                        .frame(width: 18, height: 18)
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(QuickHaze.onAccent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(verbatim: label))
            .accessibilityValue(Text(verbatim: isOn ? L("On") : L("Off")))
            .accessibilityHint(Text(verbatim: caption ?? ""))
            .accessibilityAddTraits(.isToggle)
        }
    }
}

/// The haze segmented control: options in a recessed capsule, the chosen one lit.
struct QuickSegmented<Value: Hashable>: View {
    let label: String
    let options: [(value: Value, title: String)]
    let selection: Value?
    /// Each option as wide as the others, across the row.
    var fill = false
    var segmentPadding: CGFloat = 10
    /// What an option does, under the pointer.
    var help: ((Value) -> String)?
    /// Whether an option can be chosen (all, without it).
    var enabled: ((Value) -> Bool)?
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                let selected = option.value == selection
                Button {
                    if !selected { choose(option.value) }
                } label: {
                    Text(verbatim: option.title)
                        .font(QuickHaze.mona(12.5, selected ? 600 : 400))
                        .foregroundStyle(selected ? QuickHaze.accentText : QuickHaze.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .padding(.horizontal, fill ? 4 : segmentPadding)
                        .frame(maxWidth: fill ? .infinity : nil)
                        .frame(height: 24)
                        .background {
                            if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).fill(QuickHaze.segmentSelection) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!(enabled?(option.value) ?? true))
                .opacity(enabled?(option.value) ?? true ? 1 : 0.45)
                .help(help?(option.value) ?? "")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(QuickHaze.inset))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: label))
    }
}

private struct QuickMenuOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var enabled = true
    var id: String { title }
}

/// A pop-up choice in a recessed capsule (render scale, Translate Into),
/// its choices in a haze menu (HazeMenu.swift).
private struct QuickMenu<Value: Hashable>: View {
    let label: String
    let title: String
    let options: [QuickMenuOption<Value>]
    let selection: Value
    let choose: (Value) -> Void

    var body: some View {
        HazeMenuButton(matchesWidth: true) {
            options.map { option -> HazeMenuEntry in
                .item(HazeMenuItem(title: option.title, state: option.value == selection ? .on : .off, isEnabled: option.enabled) {
                    if option.value != selection { choose(option.value) }
                })
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: title)
                    .font(QuickHaze.mona(12.5, 600))
                    .foregroundStyle(QuickHaze.accentText)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(QuickHaze.textTertiary)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: 170)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(QuickHaze.inset))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: title))
    }
}

/// The haze slider: an Avo green fill and thumb on a dark track. Drag or
/// click anywhere on it; arrow keys and VoiceOver step it.
struct QuickSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    /// What VoiceOver reads for the value ("35%").
    var valueText: Text?
    /// Begins and ends a drag (for saving only when it ends).
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragging = false

    private let thumb: CGFloat = 15

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width - thumb)
            let fraction = (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound)
                / max(range.upperBound - range.lowerBound, .ulpOfOne)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.black.opacity(0.35))
                    .overlay { Capsule().strokeBorder(QuickHaze.text.opacity(0.12)) }
                    .frame(height: 5)
                    .padding(.horizontal, thumb / 2)
                Capsule().fill(QuickHaze.accent)
                    .frame(width: thumb / 2 + width * fraction, height: 5)
                    .padding(.leading, thumb / 2)
                Circle()
                    .fill(QuickHaze.accent)
                    .overlay { Circle().strokeBorder(QuickHaze.onAccent.opacity(0.25)) }
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .frame(width: thumb, height: thumb)
                    .offset(x: width * fraction)
            }
            .frame(height: geometry.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in
                    if !dragging {
                        dragging = true
                        onEditingChanged(true)
                    }
                    set(fraction: (drag.location.x - thumb / 2) / width)
                }
                .onEnded { _ in
                    dragging = false
                    onEditingChanged(false)
                })
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(valueText ?? Text(value, format: .number))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + step)
            case .decrement: value = max(range.lowerBound, value - step)
            @unknown default: break
            }
        }
    }

    private func set(fraction: CGFloat) {
        let raw = range.lowerBound + Double(min(max(fraction, 0), 1)) * (range.upperBound - range.lowerBound)
        let snapped = ((raw - range.lowerBound) / step).rounded() * step + range.lowerBound
        let clamped = min(max(snapped, range.lowerBound), range.upperBound)
        if abs(clamped - value) > step / 1000 { value = clamped }
    }
}
