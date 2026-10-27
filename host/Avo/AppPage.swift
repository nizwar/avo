import AvoHazeUI
import AvoKeymap
import AvoKit
import AvoWindowHost
import SwiftUI

/// An app's page in the Library, over the whole window: a hero in the
/// colours of its icon, how much it was played this week, its graphics and
/// controls, storage, and its permissions; every setting right here, not in
/// a dialog. Games and apps share the page; apps without a key mapping get
/// a smaller Controls card.
struct AppPage: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    let app: AppRecord
    @State private var keyMapping: KeymapProfile?
    @State private var allGraphics = false
    @State private var confirmUninstall = false
    @State private var confirmClear = false
    /// The page has arrived: its colours fade in, the hero and cards rise into place.
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The status pill's room at the window's bottom (nil in offscreen renders).
    @Environment(StatusPillRoom.self) private var pillRoom: StatusPillRoom?

    var body: some View {
        let palette = IconPaletteCache.shared.palette(for: app.package, icon: model.icons[app.package])
        let game = model.isGame(app)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(palette: palette, game: game)
                LibraryBanners()
                    .padding(.horizontal, 14)
                VStack(alignment: .leading, spacing: 22) {
                    SpanRow(spans: [5, 4, 3], spacing: 22) {
                        PageCard { AppUsageCard(usage: model.usage[app.package], palette: palette, isGame: game) }
                            .hazeEntrance(appeared, delay: 0.10)
                        PageCard { AppGraphicsCard(app: app, showsAll: $allGraphics) }
                            .hazeEntrance(appeared, delay: 0.14)
                        PageCard { AppControlsCard(app: app, keyMapping: keyMapping) }
                            .hazeEntrance(appeared, delay: 0.18)
                    }
                    if allGraphics {
                        AllGraphicsCard(app: app)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                    }
                    StorageStrip(app: app, confirmClear: $confirmClear, confirmUninstall: $confirmUninstall)
                        .hazeEntrance(appeared, delay: 0.22)
                    PermissionsCard(app: app)
                        .hazeEntrance(appeared, delay: 0.26)
                }
                .padding(.horizontal, 48)
                .padding(.top, 26)
                .padding(.bottom, 24)
            }
            .background(alignment: .top) {
                // The icon's colours fade in with the page, and again if the icon changes.
                ZStack {
                    HeroBackground(palette: palette)
                        .id(palette.accent)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.6), value: palette)
                .opacity(appeared ? 1 : 0)
                .animation(.easeOut(duration: 0.7), value: appeared)
            }
        }
        .windowDragArea()
        .scrollIndicators(.hidden)
        // The page ends above the status pill, which covers none of it.
        .padding(.bottom, pillRoom?.bottom ?? 0)
        .background(Haze.pageBase)
        .onAppear { appeared = true }
        .overlay(alignment: .topLeading) {
            Button { router.page = nil } label: {
                Label("Library", systemImage: "chevron.left").labelStyle(HazeLabelStyle(spacing: 6, iconSize: 12))
            }
            .buttonStyle(BackButtonStyle())
            .keyboardShortcut("[", modifiers: .command)
            .padding(.leading, 92)
            .padding(.top, 10)
        }
        .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: allGraphics)
        .task(id: app.package) {
            // Game or app, and the preset the graphics start from, follow
            // the key mappings, which the app's window may have changed since.
            model.refreshKeyMappings()
            keyMapping = await Self.mapping(for: app.package)
        }
        .onChange(of: model.keyMappedPackages) {
            Task { keyMapping = await Self.mapping(for: app.package) }
        }
        .confirmationDialog(String(localized: "Uninstall \(app.displayName)?"), isPresented: $confirmUninstall, titleVisibility: .visible) {
            Button("Uninstall", role: .destructive) { model.uninstall(app) }
        } message: {
            Text("The app, its data and its shortcut in Android Apps are removed.")
        }
        .confirmationDialog("Clear all data of \(app.displayName)?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear Data", role: .destructive) { model.deleteData(app) }
        } message: {
            Text("Accounts, settings and files stored by the app are deleted.")
        }
    }

    /// The More menu: what the page has no button for, as in the menu on
    /// the app's tile (AppMenu).
    private var moreActions: [HazeMenuEntry] {
        var entries: [HazeMenuEntry] = [
            .item(HazeMenuItem(title: String(localized: "Force Stop"), symbol: "stop.circle",
                               isEnabled: model.activity[app.package] != nil) { model.forceStop(app) }),
        ]
        if let shim = app.shortcuts.shimPath {
            entries.append(.item(HazeMenuItem(title: String(localized: "Show in Finder"), symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: shim)])
            }))
        }
        entries.append(.separator())
        entries.append(.item(HazeMenuItem(title: String(localized: "Clear Data…"), symbol: "eraser") { confirmClear = true }))
        if !app.systemApp {
            entries.append(.item(HazeMenuItem(title: String(localized: "Uninstall…"), symbol: "trash", role: .destructive) {
                confirmUninstall = true
            }))
        }
        return entries
    }

    /// The app's key mapping; one without controls counts as none.
    private static func mapping(for package: String) async -> KeymapProfile? {
        guard let profile = await loadKeyMapping(for: package), !profile.controls.isEmpty else { return nil }
        return profile
    }

    // MARK: Header

    private func header(palette: IconPalette, game: Bool) -> some View {
        HStack(alignment: .bottom, spacing: 28) {
            // The hero icon turns toward the pointer anywhere around it and
            // catches its light; it arrives with a small pop.
            AppIconView(icon: model.icons[app.package], size: 132, cornerRadius: 32)
                .overlay { RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(Haze.highlight.opacity(0.1)) }
                .hazeEdgeLight(cornerRadius: 32, reach: 260)
                .shadow(color: Haze.shadow.opacity(0.6), radius: 30, y: 24)
                .hazeTilt(degrees: 6, reach: 560)
                .scaleEffect(appeared || reduceMotion ? 1 : 0.9)
                .opacity(appeared ? 1 : 0)
                .animation(Haze.Motion.animation(.spring(response: 0.5, dampingFraction: 0.76), reduceMotion: reduceMotion).delay(0.04),
                           value: appeared)
            VStack(alignment: .leading, spacing: 10) {
                (Text(game ? "Game" : "App") + Text(verbatim: " · ") + Text(model.source(of: app)))
                    .textCase(.uppercase)
                    .font(.hazeMono(11))
                    .tracking(1.6)
                    .foregroundStyle(Haze.tint(palette.accent))
                Text(app.displayName)
                    .font(.hubot(46, 800))
                    .tracking(-0.8)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                    .hazeLineHeight(1.0, size: 46)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    if let activity = model.activity[app.package] {
                        HazeChip(Text(activity.labelResource), fill: Haze.heroChip)
                    }
                    if let keyMapping {
                        HazeChip(Text("Key mapping · \(keyMapping.controls.count) controls"), fill: Haze.heroChip)
                        if keyMapping.usesGamepad {
                            HazeChip(Text("Gamepad mapped"), fill: Haze.heroChip)
                        }
                    }
                    if !app.versionName.isEmpty {
                        HazeChip(Text("Version \(app.versionName)"), fill: Haze.heroChip)
                            .help(app.package)
                    }
                }
            }
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hazeEntrance(appeared, delay: 0.07, rise: 10)
            HStack(spacing: 10) {
                Button { model.open(app) } label: {
                    Label("Open", systemImage: "play.fill").labelStyle(HazeLabelStyle(spacing: 8, iconSize: 13))
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 46, fontSize: 15, horizontalPadding: 26))
                .shadow(color: Haze.accent.opacity(0.25), radius: 15, y: 10)
                .keyboardShortcut(.defaultAction)
                // In the haze, as the app's menu on its tile (AppMenu).
                HazeMenuButton { moreActions } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 46, height: 46)
                        .background(Haze.heroChip, in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel(Text("More actions"))
            }
            .padding(.bottom, 8)
            .hazeEntrance(appeared, delay: 0.12, rise: 10)
        }
        .padding(.horizontal, 48)
        .padding(.top, 78)
        .frame(height: 300, alignment: .bottom)
    }
}

/// The hero's colours: glows from the icon over Avo's dark green (or its
/// paper, in the light look), fading into the page.
/// Its glows lean toward the pointer, slowly, like light through mist.
private struct HeroBackground: View {
    let palette: IconPalette

    var body: some View {
        ZStack(alignment: .top) {
            ZStack {
                HazeBackground(linear: HazeLinear(angle: 105, stops: [.init(color: 0x12160D, location: 0), .init(color: 0x232816, location: 0.45),
                                                                       .init(color: palette.baseEnd(from: 0x232816, amount: 0.18), location: 1)]))
                HazeDriftingGlows(layers: [
                    .init(glow: HazeGlow(x: .fraction(0.74), y: .fraction(0.30), rx: 520, ry: 300, color: palette.accent, alpha: 0.62), pull: 0.07),
                    .init(glow: HazeGlow(x: .fraction(1), y: .fraction(0.90), rx: 600, ry: 320, color: palette.deep, alpha: 0.6, stop: 0.72), pull: 0.03),
                    .init(glow: HazeGlow(x: .fraction(0.30), y: .fraction(-0.10), rx: 420, ry: 260, color: 0xD8E8A7, alpha: 0.16), pull: -0.03),
                ], limit: 48)
            }
            .frame(height: 380)
            .clipped()
            LinearGradient(colors: [Haze.pageBase.opacity(0), Haze.pageBase], startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .padding(.top, 230)
        }
        .frame(height: 390, alignment: .top)
        .accessibilityHidden(true)
    }
}

private struct BackButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        BackButtonBody(configuration: configuration)
    }
}

/// Lighter under the pointer, pressed in a touch when clicked.
private struct BackButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.mona(13))
            .foregroundStyle(Haze.text)
            .padding(.leading, 8)
            .padding(.trailing, 12)
            .frame(height: 30)
            .background(Color(haze: 0x000000, alpha: configuration.isPressed ? 0.4 : hovering ? 0.36 : 0.28,
                               light: 0xFFFFFF, lightAlpha: configuration.isPressed ? 0.85 : hovering ? 0.75 : 0.6), in: Capsule())
            .contentShape(Capsule())
            .scaleEffect(configuration.isPressed && !reduceMotion ? Haze.Motion.pressScale : 1)
            .animation(Haze.Motion.press, value: configuration.isPressed)
            .animation(Haze.Motion.hover, value: hovering)
            .onHover { hovering = $0 }
    }
}

/// A card on an app's page.
struct PageCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// The design's 12-column row: each card spans some columns, all as tall as
/// the tallest.
struct SpanRow: Layout {
    var spans: [Int]
    var columns = 12
    var spacing: CGFloat

    private func widths(_ total: CGFloat) -> [CGFloat] {
        let column = (total - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return spans.map { CGFloat($0) * column + CGFloat($0 - 1) * spacing }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let widths = widths(width)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

// MARK: - Graphics

/// The settings a player changes most, for this app only: resolution,
/// MetalFX, sharpness, and Android's frame rate cap. Everything else is in
/// All Graphics Settings below, the same form as the old sheet.
private struct AppGraphicsCard: View {
    /// The resolutions the card offers, to fit its width.
    private static let resolutions = [720, 1080, 1440, 2160]
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord
    @Binding var showsAll: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 4) {
                Text("Graphics").font(.mona(15, 600))
                HelpButton("Graphics", "These settings are for this app only and apply to its windows right away. Max FPS is Android’s, for every app.")
            }
            if let resolved = model.graphics(for: app.package), let config = model.config {
                let settings = resolved.settings
                let mode = settings.effectiveMode(device: model.deviceProfile?.display)
                // The profile the app's graphics start from, switched right here.
                let automatic: GraphicsProfile = model.hasKeyMapping(app.package) || model.listedAsGame(app.package) ? .games : .apps
                HazeRows {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Preset").font(.mona(12)).foregroundStyle(Haze.textTertiary)
                            HelpButton("Preset", "Apps, Games and Phone are the presets in Settings › Graphics. Avo picks Apps or Games by itself (an app with key mapping, or one Android lists as a game, is a game). Phone gives the app the screen of the phone in Settings › Privacy, at its density, as on that phone. The changes made on this page stay on top of any of them.")
                        }
                        HazeSegmented(options: [(GraphicsProfile.apps, Text("Apps")), (GraphicsProfile.games, Text("Games")),
                                                (GraphicsProfile.phone, Text("Phone"))],
                                      selection: Binding(get: { resolved.profile }, set: { choice in
                                          // As in All Graphics Settings: the app keeps what it changed,
                                          // minus what the new profile already has.
                                          let base = config.settings(for: choice)
                                          model.setAppGraphics(AppGraphicsOverride(profile: choice == automatic ? nil : choice,
                                                                                   changes: .difference(resolved.changes.applied(to: base), from: base)),
                                                               for: app.package)
                                      }),
                                      height: 32, cornerRadius: 12, fill: Haze.inset, selectedFill: Haze.accent.opacity(0.2),
                                      segmentPadding: 4, equalWidths: true)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Resolution").font(.mona(12)).foregroundStyle(Haze.textTertiary)
                        // Adaptive, like All Graphics Settings. A fixed
                        // resolution is the player's to pick (Games); the
                        // phone's screen (Phone, from the device profile) and
                        // the window's (Apps) are shown, not set here — those
                        // change in All Graphics Settings.
                        switch mode {
                        case .fixed:
                            // The big steps; All Graphics Settings has every one.
                            HazeSegmented(options: Self.resolutions.map { ($0, Text(verbatim: GraphicsSettings.resolutionName($0))) },
                                          selection: Binding(get: { settings.shortSide }, set: { value in
                                              var changed = settings
                                              changed.mode = .fixed
                                              changed.shortSide = value
                                              model.setAppGraphicsSettings(changed, for: app.package)
                                          }),
                                          height: 32, cornerRadius: 12, fill: Haze.inset, selectedFill: Haze.accent.opacity(0.2),
                                          segmentPadding: 4, equalWidths: true)
                            if !Self.resolutions.contains(settings.shortSide) {
                                Text("Fixed at \(GraphicsSettings.resolutionName(settings.shortSide))")
                                    .font(.mona(12)).foregroundStyle(Haze.textTertiary)
                            }
                        case .deviceProfile:
                            let phone = model.deviceProfile
                            ResolutionReadout(value: phone?.display.map { "\($0.width) × \($0.height) · \($0.dpi) dpi" } ?? "—",
                                              note: "Phone\(phone.map { " (\($0.name))" } ?? "") — from the device profile")
                        case .followWindow:
                            ResolutionReadout(value: "Follows the window",
                                              note: "\(settings.renderScale)% render scale")
                        }
                    }
                    HStack(spacing: 4) {
                        Toggle(isOn: Binding(get: { settings.filter == .metalFXSpatial }, set: { on in
                            var changed = settings
                            changed.filter = on ? .metalFXSpatial : .bilinear
                            model.setAppGraphicsSettings(changed, for: app.package)
                        })) {
                            HStack(spacing: 4) {
                                Text("Sharp upscaling").font(.mona(14))
                                HelpButton("Sharp upscaling", "Apple’s MetalFX keeps edges and text sharp when the picture is enlarged. Best for most games.")
                            }
                        }
                        .toggleStyle(HazeCheckboxStyle())
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        SharpnessSlider(value: settings.sharpness, enabled: settings.filter != .nearest) { value in
                            var changed = settings
                            changed.sharpness = value
                            model.setAppGraphicsSettings(changed, for: app.package)
                        }
                    }
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Max FPS").font(.mona(14)).lineLimit(1)
                            HelpButton("Max FPS", "Android draws at most this many frames per second, in every app. A screen’s own rate between 60 and 120 appears too, so Android runs in step with it. A rate above the one Android started at applies after a restart. 30 saves power and heat.")
                        }
                        Spacer(minLength: 4)
                        let rates = FrameRates.choices(for: ScreenRefresh.attached, keeping: config.fpsLimit)
                        HazeSegmented(options: rates.map { ($0, Text(verbatim: "\($0)")) },
                                      selection: Binding(get: { config.fpsLimit },
                                                         set: { value in model.update { $0.fpsLimit = value } }),
                                      height: 28, cornerRadius: 10, fontSize: 12, fill: Haze.inset, selectedFill: Haze.accent.opacity(0.2),
                                      segmentPadding: 8)
                            .fixedSize()
                    }
                    FrameRateNote(cap: config.fpsLimit)
                    IssueText(field: "graphicsOverrides.\(app.package).sharpness")
                    Button(showsAll ? "Hide Graphics Settings" : "All Graphics Settings…") { showsAll.toggle() }
                        .buttonStyle(HazeLinkButtonStyle())
                        .font(.mona(13))
                        .foregroundStyle(Haze.accent)
                }
            } else {
                // Its controls' shapes until the settings arrive.
                HazeSkeleton(bars: [(0.3, 10), (1, 32), (0.36, 10), (1, 32), (0.7, 16), (0.9, 16)])
                    .transition(.opacity)
            }
        }
    }
}

/// A read-only resolution in the quick card: the phone's screen, or the
/// window's, shown as a filled box the height of the resolution picker it
/// stands in for, with a note under it. (The editable picker is Games only.)
private struct ResolutionReadout: View {
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: value)
                .font(.mona(13))
                .foregroundStyle(Haze.text)
                .monospacedDigit()
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Haze.inset))
            Text(verbatim: note).font(.mona(12)).foregroundStyle(Haze.textTertiary)
        }
    }
}

/// Sharpness, written once the thumb is let go (keyboard changes at once).
private struct SharpnessSlider: View {
    let value: Int
    let enabled: Bool
    let commit: (Int) -> Void
    @State private var draft: Double?

    var body: some View {
        let shown = Int((draft ?? Double(value)).rounded())
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Sharpness").font(.mona(14))
                Spacer()
                Group {
                    if shown == 0 { Text("Off") } else { Text(Double(shown) / 100, format: .percent) }
                }
                .font(.mona(14))
                .foregroundStyle(Haze.textTertiary)
                .monospacedDigit()
            }
            HazeSlider(value: Binding(get: { draft ?? Double(value) }, set: { newValue in
                if draft == nil { commit(Int(newValue.rounded())) } else { draft = newValue }
            }), range: Double(GraphicsSettings.sharpnessRange.lowerBound)...Double(GraphicsSettings.sharpnessRange.upperBound),
               step: Double(GraphicsSettings.sharpnessStep)) { editing in
                if editing {
                    draft = Double(value)
                } else if let draft {
                    self.draft = nil
                    let committed = Int(draft.rounded())
                    if committed != value { commit(committed) }
                }
            }
            .accessibilityLabel(Text("Sharpness"))
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }
}

/// The same form as the old Graphics Settings sheet, inline.
private struct AllGraphicsCard: View {
    let app: AppRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("All Graphics Settings").font(.mona(15, 600))
                .padding(.horizontal, 22)
                .padding(.top, 18)
            // Its sections in this card, laid out as Settings' cards are.
            AppGraphicsForm(app: app)
                .formStyle(HazeFormStyle(embedded: true))
                .padding(.horizontal, 22)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Controls

/// The app window's own settings (kept by its App Shim) and its key mapping.
private struct AppControlsCard: View {
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord
    let keyMapping: KeymapProfile?
    @State private var gameMode = false
    @State private var keyHints = true
    @State private var keyMappingHover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 4) {
                Text("Game controls").font(.mona(15, 600))
                HelpButton("Game controls") {
                    Text("Game Mode turns keys and clicks into touches with the app’s key mapping. ⌘G turns it on and off in the app’s window; a new window starts the way the last one ended.")
                    Text("The key mapping is edited over the game: Create Key Mapping… (or Edit) below opens the app with the editor. In its window, choose Game Controls › Edit Key Mapping or press ⇧⌘K.")
                }
            }
            if keyMapping != nil {
                Toggle(isOn: Binding(get: { gameMode }, set: { gameMode = $0; ShimPreferences(package: app.package).gameModeAtStart = $0 })) {
                    Text("Game Mode at start").font(.mona(14))
                }
                .toggleStyle(HazeCheckboxStyle())
                Toggle(isOn: Binding(get: { keyHints }, set: { keyHints = $0; ShimPreferences(package: app.package).keyHintsVisible = $0 })) {
                    Text("Show keys on game").font(.mona(14))
                }
                .toggleStyle(HazeCheckboxStyle())
            } else {
                Text("No key mapping yet")
                    .font(.mona(13))
                    .foregroundStyle(Haze.textTertiary)
            }
            Button {
                model.editKeyMapping(app)
            } label: {
                Text(keyMapping == nil ? "Create Key Mapping…" : "Edit Key Mapping…")
                    .font(.mona(13, 600))
                    .foregroundStyle(Haze.accentText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Haze.accent.opacity(keyMappingHover ? 0.18 : 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(HazeCardButtonStyle())
            .hazeHover($keyMappingHover)
            .help("Opens the app with the key mapping editor over the game. In its window, ⇧⌘K opens it too.")
        }
        .onAppear {
            let preferences = ShimPreferences(package: app.package)
            gameMode = preferences.gameModeAtStart
            keyHints = preferences.keyHintsVisible
        }
    }
}

// MARK: - Storage

/// The app's size on Android's data disk, and the ways to free it.
private struct StorageStrip: View {
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord
    @Binding var confirmClear: Bool
    @Binding var confirmUninstall: Bool
    /// The bar fills from empty when the page arrives.
    @State private var filled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Android's own storage as it last said (Settings › Storage).
        let android = model.dataDisk?.android
        let disk = android?.dataBytes ?? 0
        let size = app.sizeBytes ?? 0
        HStack(spacing: 22) {
            HStack(spacing: 4) {
                Text("Storage").font(.mona(14, 600))
                HelpButton("Storage", "The app’s own size on Android’s data disk. Its data and cache come on top.")
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Haze.track)
                    if disk > 0, size > 0 {
                        Capsule().fill(Haze.accent)
                            .frame(width: max(6, geometry.size.width * min(1, Double(size) / Double(disk)) * (filled || reduceMotion ? 1 : 0)))
                    }
                }
                .animation(.spring(response: 0.9, dampingFraction: 0.9).delay(0.3), value: filled)
            }
            .frame(height: 8)
            .accessibilityHidden(true)
            .onAppear { filled = true }
            // The disk as Settings › Storage says it ("64 GB").
            Group {
                if let android { Text("\(formatBytes(size)) of \(android.settingsTotalGB) GB") } else { Text(verbatim: formatBytes(size)) }
            }
                .font(.mona(12))
                .foregroundStyle(Haze.textSecondary)
                .lineLimit(1)
                .fixedSize()
            Button("Clear Data…") { confirmClear = true }
                .buttonStyle(HazeButtonStyle(kind: .secondary, height: 32, fontSize: 13, horizontalPadding: 14))
            if !app.systemApp {
                Button("Uninstall…") { confirmUninstall = true }
                    .buttonStyle(HazeButtonStyle(kind: .destructive, height: 32, fontSize: 13, horizontalPadding: 14))
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

// MARK: - Permissions

/// What the app may use, as in Android's own App info (asked from Android).
private struct PermissionsCard: View {
    @Environment(ControlPanelModel.self) private var model
    let app: AppRecord
    @State private var permissions: [AppPermission]?
    /// Android did not say (busy, or the daemon went away): why, with Try Again.
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Permissions").font(.mona(15, 600))
            if model.status.state != .running {
                HStack(spacing: 12) {
                    Text("Start Android to see what this app may use.")
                        .font(.mona(13))
                        .foregroundStyle(Haze.textTertiary)
                    Spacer()
                    Button("Start Android") { model.startVM() }
                        .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 14))
                        .disabled(model.status.state.isBusy || model.daemonState != .connected)
                }
            } else if let failure, permissions == nil {
                HStack(spacing: 12) {
                    Text("Android did not say what this app may use. \(failure)")
                        .font(.mona(13))
                        .foregroundStyle(Haze.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 14))
                }
            } else if let permissions {
                let runtime = permissions.filter(\.runtime)
                if runtime.isEmpty {
                    Text("This app has no permissions you can change.")
                        .font(.mona(13))
                        .foregroundStyle(Haze.textTertiary)
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28), GridItem(.flexible(), spacing: 28)], alignment: .leading, spacing: 12) {
                        ForEach(runtime, id: \.name) { permission in
                            Toggle(isOn: Binding(get: { permission.granted }, set: { granted in
                                Task {
                                    await model.setPermission(permission, granted: granted, for: app)
                                    // What Android has now; the list stays as it was if it does not say.
                                    if let now = try? await model.permissions(for: app) { self.permissions = now }
                                }
                            })) {
                                Text(PermissionNames.label(for: permission.name, fallback: permission.label))
                                    .font(.mona(14))
                                    .lineLimit(1)
                            }
                            .toggleStyle(HazeCheckboxStyle())
                        }
                    }
                }
            } else {
                HazeSkeleton(bars: [(0.4, 14), (0.32, 14), (0.46, 14)], spacing: 12)
                    .frame(maxWidth: 420)
                    .transition(.opacity)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .animation(Haze.Motion.fade, value: permissions == nil)
        .task(id: "\(app.package)-\(model.status.state.rawValue)") {
            guard model.status.state == .running else { return }
            await load()
        }
    }

    private func load() async {
        do {
            permissions = try await model.permissions(for: app)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
    }
}
