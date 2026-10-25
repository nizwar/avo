import AvoKit
import SwiftUI

// Library › Home: the game to continue, a row of games, and the apps; the
// Library section's All, Games and Apps tabs; and Home's search results.

struct LibraryHome: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                if let game = model.continueGame {
                    ContinuePlayingHero(game: game)
                } else {
                    WelcomeHero()
                }
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "Games", seeAll: model.games.count > 1 ? { router.showLibrary(.games) } : nil)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: 3), spacing: 16) {
                        ForEach(homeGames) { game in
                            GameCard(app: game)
                        }
                        ForEach(actionCards, id: \.self) { card in
                            card.view
                        }
                    }
                }
                if !model.nonGameApps.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Apps", seeAll: model.nonGameApps.count > 6 ? { router.showLibrary(.apps) } : nil)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 6), spacing: 14) {
                            ForEach(model.nonGameApps.prefix(6)) { app in
                                LibraryAppTile(app: app)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 34)
            // The status pill has its own room below (LibraryView).
            .padding(.bottom, 24)
        }
        .windowDragArea()
        .scrollIndicators(.hidden)
    }

    /// Up to three cards in the row: recent games, then ways to get more.
    private var homeGames: [AppRecord] { Array(model.games.prefix(3)) }

    private var actionCards: [ActionCard] {
        let room = 3 - homeGames.count
        guard room > 0 else { return [] }
        let cards: [ActionCard] = [model.storeApp.map(ActionCard.store) ?? .googleApps, .file]
        return Array(cards.prefix(room))
    }
}

/// The ways to get another game.
private enum ActionCard: Hashable {
    case store(AppRecord)
    /// No store app: Settings › Google Apps.
    case googleApps
    case file

    @MainActor @ViewBuilder var view: some View {
        switch self {
        case .store(let store): StoreCard(store: store)
        case .googleApps: GoogleAppsCard()
        case .file: FileCard()
        }
    }
}

private struct StoreCard: View {
    @Environment(ControlPanelModel.self) private var model
    let store: AppRecord

    var body: some View {
        QuietCard(title: "Get more games", detail: Text("Opens \(store.displayName) in its own window")) {
            model.open(store)
        }
    }
}

private struct GoogleAppsCard: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        QuietCard(title: "Get Google Play", detail: Text("Install Google apps in Settings")) {
            router.requestedSettingsPane = .googleApps
            openWindow(id: SettingsWindow.id)
        }
    }
}

private struct FileCard: View {
    @Environment(ControlPanelModel.self) private var model

    var body: some View {
        QuietCard(title: "Install from a file", detail: Text("Drop an .apk or .xapk anywhere here")) {
            model.chooseAndInstall()
        }
    }
}

/// The plain cards beside the games (design: "Get more games").
private struct QuietCard: View {
    let title: LocalizedStringKey
    let detail: Text
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.mona(15, 600)).foregroundStyle(Haze.text)
                detail.font(.mona(13)).foregroundStyle(Haze.textSecondary)
            }
            .lineLimit(2)
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 112, maxHeight: 112, alignment: .leading)
            .background(hovering ? Haze.text.opacity(0.075) : Haze.cardQuiet, in: shape)
            .hazeCard(hovering: hovering, cornerRadius: 16)
            .contentShape(shape)
        }
        .buttonStyle(HazeCardButtonStyle())
        .hazeHover($hovering)
    }
}

/// "Games" and its See all link.
struct SectionHeader: View {
    let title: LocalizedStringKey
    var seeAll: (() -> Void)?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.hubot(20, 700))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            if let seeAll {
                Button("See all", action: seeAll)
                    .buttonStyle(HazeLinkButtonStyle())
                    .font(.mona(13))
                    .foregroundStyle(Haze.accent)
            }
        }
    }
}

// MARK: - The hero

/// The last game played, with its colours, ready to continue.
private struct ContinuePlayingHero: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let game: AppRecord
    @State private var hovering = false

    var body: some View {
        let palette = IconPaletteCache.shared.palette(for: game.package, icon: model.icons[game.package])
        let usage = model.usage[game.package]
        let nudged = hovering && !reduceMotion
        ZStack(alignment: .leading) {
            // The game's colours bloom in as its icon arrives.
            ZStack {
                HazeBackground(base: Color(haze: 0x16190F),
                               linear: HazeLinear(angle: 110, stops: [.init(color: 0x10140C, location: 0), .init(color: 0x1E2514, location: 0.46),
                                                                      .init(color: palette.baseEnd(from: 0x1E2514, amount: 0.14), location: 1)]),
                               glows: [HazeGlow(x: .fraction(0.78), y: .fraction(0.30), rx: 420, ry: 260, color: palette.accent, alpha: 0.55),
                                       HazeGlow(x: .fraction(1), y: .fraction(1), rx: 520, ry: 300, color: palette.deep, alpha: 0.55),
                                       HazeGlow(x: .fraction(0.55), y: .fraction(-0.20), rx: 380, ry: 240, color: 0xD8E8A7, alpha: 0.20)])
                    .id(palette.accent)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.6), value: palette)
            AppIconView(icon: model.icons[game.package], size: 156, cornerRadius: 38)
                .overlay { RoundedRectangle(cornerRadius: 38, style: .continuous).strokeBorder(.white.opacity(0.08)) }
                .hazeEdgeLight(cornerRadius: 38, reach: 240)
                .scaleEffect(nudged ? 1.03 : 1)
                .rotationEffect(.degrees(nudged ? -6 : -4))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 24)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 64)
            VStack(alignment: .leading, spacing: 12) {
                Text(usage?.lastUsed() == nil ? "Ready to play" : "Continue playing")
                    .textCase(.uppercase)
                    .font(.hazeMono(11))
                    .tracking(1.6)
                    .foregroundStyle(Color(haze: palette.accent))
                Text(game.displayName)
                    .font(.hubot(40, 750))
                    .tracking(-0.6)
                    .lineLimit(2)
                    .hazeLineHeight(1.05, size: 40)
                if let line = playLine(usage) {
                    Text(line).font(.mona(14)).foregroundStyle(Color(haze: 0xD9DCCD))
                }
                HStack(spacing: 8) {
                    ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in HazeChip(chip) }
                }
                HStack(spacing: 10) {
                    Button { model.open(game) } label: {
                        Label("Play", systemImage: "play.fill").labelStyle(HazeLabelStyle(spacing: 8, iconSize: 13))
                    }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 44, fontSize: 15, horizontalPadding: 22))
                    Button("Game page") { router.open(game) }
                        .buttonStyle(HazeButtonStyle(kind: .secondary, height: 44, fontSize: 15, horizontalPadding: 20))
                        .environment(\.hazeSecondaryFill, Haze.text.opacity(0.12))
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 40)
            .frame(maxWidth: 560, maxHeight: .infinity, alignment: .leading)
        }
        .frame(height: 262)
        .hazePointerGlow(hovering, cornerRadius: 22, color: Color(haze: palette.accent))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // A wide card turns less.
        .hazeTilt(hovering, degrees: 2.5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .hazeHover($hovering)
        .appTileActions(game, cornerRadius: 22, pressScale: 0.995, accessible: false)
        .accessibilityElement(children: .contain)
    }

    /// "Last played 2 hours ago · 1 hr 42 min this week".
    private func playLine(_ usage: AppUsage?) -> String? {
        guard let usage, let last = usage.lastUsed() else { return nil }
        let week = usage.week(containing: Date()).seconds
        let played = usage.isOnScreen ? String(localized: "Playing now") : String(localized: "Last played \(formatAgo(last))")
        guard week >= 60 else { return played }
        return played + " · " + String(localized: "\(formatPlayTime(week)) this week")
    }

    /// What the game runs with: renderer and frame cap, key mapping, resolution.
    private var chips: [Text] {
        var chips: [Text] = []
        if let config = model.config {
            let renderer = model.status.renderer?.mode == .software ? Text("Software") : Text(verbatim: "GPU")
            chips.append(renderer + Text(verbatim: " · ") + Text("\(config.fpsLimit) FPS"))
        }
        if model.hasKeyMapping(game.package) { chips.append(Text("Key mapping")) }
        if let graphics = model.graphics(for: game.package)?.settings {
            chips.append(Text(graphics.summaryChip(device: model.deviceProfile?.display)))
        }
        return chips
    }
}

/// Home before any game is installed.
private struct WelcomeHero: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .leading) {
            HazeBackground(base: Color(haze: 0x16190F),
                           linear: HazeLinear(angle: 110, stops: [.init(color: 0x10140C, location: 0), .init(color: 0x1E2514, location: 0.46),
                                                                  .init(color: 0x2A3A1C, location: 1)]),
                           glows: [HazeGlow(x: .fraction(0.78), y: .fraction(0.30), rx: 420, ry: 260, color: 0xBCDC8F, alpha: 0.40),
                                   HazeGlow(x: .fraction(1), y: .fraction(1), rx: 520, ry: 300, color: 0x4F6B2E, alpha: 0.55),
                                   HazeGlow(x: .fraction(0.55), y: .fraction(-0.20), rx: 380, ry: 240, color: 0xD8E8A7, alpha: 0.20)])
            AvoMark()
                .frame(width: 150, height: 150)
                .scaleEffect(hovering && !reduceMotion ? 1.03 : 1)
                .rotationEffect(.degrees(hovering && !reduceMotion ? -7 : -4))
                .shadow(color: .black.opacity(0.45), radius: 26, y: 20)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 70)
            VStack(alignment: .leading, spacing: 12) {
                Text("Your library")
                    .textCase(.uppercase)
                    .font(.hazeMono(11))
                    .tracking(1.6)
                    .foregroundStyle(Haze.running)
                Text(model.apps.isEmpty ? "Bring your Android games" : "No games yet")
                    .font(.hubot(34, 750))
                    .tracking(-0.5)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .hazeLineHeight(1.05, size: 34)
                Text("Double-click an .apk file in Finder, or drop it here. Games with a key mapping show up here.")
                    .font(.mona(14))
                    .foregroundStyle(Color(haze: 0xD9DCCD))
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.chooseAndInstall() } label: {
                    Label("Install App", systemImage: "square.and.arrow.down").labelStyle(HazeLabelStyle(spacing: 8, iconSize: 14))
                }
                .buttonStyle(HazeButtonStyle(kind: .primary, height: 44, fontSize: 15, horizontalPadding: 22))
                .padding(.top, 6)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: 560, alignment: .leading)
        }
        .frame(height: 262)
        .hazePointerGlow(hovering, cornerRadius: 22)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .hazeTilt(hovering, degrees: 2.5)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .hazeHover($hovering)
    }
}

extension GraphicsSettings {
    /// "720p · Sharp", "100% · Smooth", "Phone · Sharp".
    func summaryChip(device: DeviceProfile.Display?) -> String {
        let size = switch effectiveMode(device: device) {
        case .followWindow: renderScale.formatted(.percent.scale(1))
        case .fixed: GraphicsSettings.resolutionName(shortSide)
        case .deviceProfile: String(localized: "Phone")
        }
        let filterName = switch filter {
        case .metalFXSpatial: String(localized: "Sharp")
        case .bilinear: String(localized: "Smooth")
        case .nearest: String(localized: "Pixel art")
        }
        return "\(size) · \(filterName)"
    }
}

// MARK: - Cards and tiles

/// A game in the colours of its icon (Home's row, the Games grid).
struct GameCard: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppRecord
    var height: CGFloat = 112
    @State private var hovering = false

    var body: some View {
        let palette = IconPaletteCache.shared.palette(for: app.package, icon: model.icons[app.package])
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let nudged = hovering && !reduceMotion
        ZStack(alignment: .bottomLeading) {
            ZStack {
                HazeBackground(linear: HazeLinear(angle: 120, stops: [.init(color: 0x161C10, location: 0),
                                                                     .init(color: palette.baseEnd(from: 0x1E2514, amount: 0.10), location: 1)]),
                               glows: [HazeGlow(x: .fraction(0.9), y: .fraction(0.2), rx: 240, ry: 140, color: palette.accent, alpha: 0.45)])
                    .id(palette.accent)
                    .transition(.opacity)
            }
            .animation(.easeInOut(duration: 0.6), value: palette)
            HStack(spacing: 12) {
                // The icon tips like the hero's as the pointer arrives.
                AppIconView(icon: model.icons[app.package], size: 44, cornerRadius: 11)
                    .hazeEdgeLight(cornerRadius: 11, reach: 120)
                    .scaleEffect(nudged ? 1.08 : 1)
                    .rotationEffect(.degrees(nudged ? -4 : 0))
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.displayName).font(.mona(15, 600)).foregroundStyle(Haze.text).lineLimit(1)
                    Text(detail).font(.mona(12)).foregroundStyle(Haze.textSecondary).lineLimit(1)
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .hazePointerGlow(hovering, cornerRadius: 16, color: Color(haze: palette.accent))
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(Haze.text.opacity(hovering ? 0.14 : 0))
        }
        .hazeTilt(hovering)
        .hazeLift(hovering, shadow: true)
        .contentShape(shape)
        // Click: the game; hold: its page; right click: its menu.
        .appTileActions(app, cornerRadius: 16)
        .hazeHover($hovering)
        .help(app.package)
    }

    /// "Running · 2.4 GB", "2 hours ago · 750 MB".
    private var detail: String {
        var parts: [String] = []
        if let activity = model.activity[app.package] {
            parts.append(String(localized: activity.labelResource))
        } else if let last = model.lastUsed(app) {
            parts.append(formatAgo(last))
        }
        if let size = app.sizeBytes, size > 0 { parts.append(formatBytes(size)) }
        return parts.joined(separator: " · ")
    }
}

/// An app on Home and in Apps: icon, name, and what it is doing.
struct LibraryAppTile: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppRecord
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let nudged = hovering && !reduceMotion
        VStack(spacing: 10) {
            // The icon rises toward the pointer, its shadow deepening.
            AppIconView(icon: model.icons[app.package], size: 56, cornerRadius: 14)
                .shadow(color: .black.opacity(hovering ? 0.5 : 0.35), radius: 9, y: hovering ? 11 : 8)
                .hazeEdgeLight(cornerRadius: 14, reach: 130)
                .scaleEffect(nudged ? 1.06 : 1)
                .offset(y: nudged ? -3 : 0)
            VStack(spacing: 4) {
                Text(app.displayName)
                    .font(.mona(13, 600))
                    .foregroundStyle(Haze.text)
                    .lineLimit(1)
                Text(meta)
                    .font(.mona(11))
                    .foregroundStyle(Haze.textTertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(hovering ? Haze.text.opacity(0.07) : Haze.tile, in: shape)
        .hazeCard(hovering: hovering, cornerRadius: 16)
        .contentShape(shape)
        .appTileActions(app, cornerRadius: 16)
        .hazeHover($hovering)
        .help(app.package)
    }

    /// "Running", "412 MB", "System".
    private var meta: String {
        if let activity = model.activity[app.package] { return String(localized: activity.labelResource) }
        if app.systemApp { return String(localized: "System") }
        return formatBytes(app.sizeBytes)
    }
}

extension AppActivity {
    var labelResource: LocalizedStringResource {
        switch self {
        case .open: "Running"
        case .minimized: "Minimized"
        case .background: "In background"
        }
    }
}

// MARK: - Collections

/// The Library's All tab: every game, then every app.
struct LibraryAllCollection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        let games = filtered(model.games)
        let apps = filtered(model.nonGameApps)
        if games.isEmpty && apps.isEmpty {
            if router.search.isEmpty {
                LibraryEmpty(symbol: "square.grid.2x2", title: "No Android apps yet",
                             detail: "Double-click an .apk file in Finder, or drop it here. Apps you install from F-Droid or Aurora Store inside Android show up here too.")
            } else {
                LibraryEmpty(symbol: "magnifyingglass", title: "No results", detail: nil)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !games.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Games", seeAll: { router.tab = .games })
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: 3), spacing: 16) {
                                ForEach(games) { GameCard(app: $0, height: 132) }
                            }
                        }
                    }
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Apps", seeAll: { router.tab = .apps })
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14)], spacing: 14) {
                                ForEach(apps) { LibraryAppTile(app: $0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 24)
            }
            .windowDragArea()
            .scrollIndicators(.hidden)
        }
    }

    private func filtered(_ list: [AppRecord]) -> [AppRecord] {
        router.search.isEmpty ? list : list.filter { $0.matches(router.search) }
    }
}

/// The Library's Games tab: every game, in a grid or a list.
struct GamesCollection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        @Bindable var router = router
        let games = filtered(model.games)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Games").font(.hubot(20, 700)).accessibilityAddTraits(.isHeader)
                Text(games.count, format: .number).font(.mona(13)).foregroundStyle(Haze.textTertiary)
                Spacer()
                HazeSegmented(options: [(false, Text(Image(systemName: "square.grid.2x2"))), (true, Text(Image(systemName: "list.bullet")))],
                              selection: $router.gamesAsList, height: 26, fontSize: 12, segmentPadding: 10)
                    .fixedSize()
                    .accessibilityLabel(Text("View"))
            }
            .padding(.horizontal, 34)
            if games.isEmpty {
                LibraryEmpty(symbol: "gamecontroller", title: router.search.isEmpty ? "No games yet" : "No matching games",
                             detail: router.search.isEmpty ? "Apps with a key mapping, or set to game graphics on their page, are games." : nil)
            } else {
                ScrollView {
                    ZStack(alignment: .top) {
                        if router.gamesAsList {
                            LazyVStack(spacing: 8) {
                                ForEach(games) { GameRow(app: $0) }
                            }
                            .transition(Haze.Motion.arrival(reduceMotion: reduceMotion, rise: 6))
                        } else {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: 3), spacing: 16) {
                                ForEach(games) { GameCard(app: $0, height: 132) }
                            }
                            .transition(Haze.Motion.arrival(reduceMotion: reduceMotion, rise: 6))
                        }
                    }
                    .animation(Haze.Motion.animation(Haze.Motion.content, reduceMotion: reduceMotion), value: router.gamesAsList)
                    .padding(.horizontal, 34)
                    .padding(.bottom, 24)
                }
                .windowDragArea()
                .scrollIndicators(.hidden)
            }
        }
    }

    private func filtered(_ list: [AppRecord]) -> [AppRecord] {
        router.search.isEmpty ? list : list.filter { $0.matches(router.search) }
    }
}

/// A game in the list: its time this week and when it was last played.
private struct GameRow: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppRecord
    @State private var hovering = false

    var body: some View {
        let palette = IconPaletteCache.shared.palette(for: app.package, icon: model.icons[app.package])
        let usage = model.usage[app.package]
        HStack(spacing: 14) {
            AppIconView(icon: model.icons[app.package], size: 40, cornerRadius: 10)
                .hazeEdgeLight(cornerRadius: 10, reach: 110)
                .scaleEffect(hovering && !reduceMotion ? 1.08 : 1)
                .rotationEffect(.degrees(hovering && !reduceMotion ? -4 : 0))
            VStack(alignment: .leading, spacing: 2) {
                Text(app.displayName).font(.mona(14, 600)).lineLimit(1)
                Text(lastPlayed(usage)).font(.mona(12)).foregroundStyle(Haze.textTertiary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let activity = model.activity[app.package] {
                HStack(spacing: 6) {
                    RunningDot(size: 6)
                    Text(activity.label).font(.mona(12)).foregroundStyle(Haze.textSecondary)
                }
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(formatPlayTime(usage?.week(containing: Date()).seconds ?? 0)).font(.mona(13, 600)).monospacedDigit()
                Text("This week").font(.mona(11)).foregroundStyle(Haze.textTertiary)
            }
            .frame(width: 96, alignment: .trailing)
            Text(formatBytes(app.sizeBytes)).font(.mona(12)).foregroundStyle(Haze.textTertiary).frame(width: 70, alignment: .trailing)
            Button { model.open(app) } label: {
                Label("Play", systemImage: "play.fill").labelStyle(HazeLabelStyle(spacing: 6, iconSize: 10))
            }
            .buttonStyle(HazeButtonStyle(kind: .primary, height: 30, fontSize: 12, horizontalPadding: 14))
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(hovering ? Haze.text.opacity(0.07) : Haze.card)
                HazeBackground(glows: [HazeGlow(x: .fraction(0), y: .fraction(0.5), rx: 160, ry: 60, color: palette.accent, alpha: 0.16)])
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
        .hazeCard(hovering: hovering, cornerRadius: 14, glow: Color(haze: palette.accent), lifts: false)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .appTileActions(app, cornerRadius: 14, pressScale: 0.99)
        .hazeHover($hovering)
    }

    private func lastPlayed(_ usage: AppUsage?) -> String {
        if usage?.isOnScreen == true { return String(localized: "Playing now") }
        guard let last = usage?.lastUsed() else { return String(localized: "Not played yet") }
        return String(localized: "Last played \(formatAgo(last))")
    }
}

/// The Library's Apps tab: every app that is not a game.
struct AppsCollection: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        let apps = router.search.isEmpty ? model.nonGameApps : model.nonGameApps.filter { $0.matches(router.search) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Apps").font(.hubot(20, 700)).accessibilityAddTraits(.isHeader)
                Text(apps.count, format: .number).font(.mona(13)).foregroundStyle(Haze.textTertiary)
            }
            .padding(.horizontal, 34)
            if apps.isEmpty {
                LibraryEmpty(symbol: "square.grid.2x2", title: router.search.isEmpty ? "No Android apps yet" : "No matching apps",
                             detail: router.search.isEmpty ? "Double-click an .apk file in Finder, or drop it here. Apps you install from F-Droid or Aurora Store inside Android show up here too." : nil)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 14)], spacing: 14) {
                        ForEach(apps) { LibraryAppTile(app: $0) }
                    }
                    .padding(.horizontal, 34)
                    .padding(.bottom, 24)
                }
                .windowDragArea()
                .scrollIndicators(.hidden)
            }
        }
    }
}

/// Home's search: games and apps that match.
struct SearchResults: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router

    var body: some View {
        let games = model.games.filter { $0.matches(router.search) }
        let apps = model.nonGameApps.filter { $0.matches(router.search) }
        if games.isEmpty && apps.isEmpty {
            LibraryEmpty(symbol: "magnifyingglass", title: "No results", detail: nil)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if !games.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Games")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 16), count: 3), spacing: 16) {
                                ForEach(games) { GameCard(app: $0) }
                            }
                        }
                    }
                    if !apps.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            SectionHeader(title: "Apps")
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), spacing: 14), count: 6), spacing: 14) {
                                ForEach(apps) { LibraryAppTile(app: $0) }
                            }
                        }
                    }
                }
                .padding(.horizontal, 34)
                .padding(.bottom, 24)
            }
            .windowDragArea()
            .scrollIndicators(.hidden)
        }
    }
}

/// A calm empty state in the haze.
struct LibraryEmpty: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Haze.accent.opacity(0.8))
                .frame(width: 64, height: 64)
                .background(Haze.text.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            Text(title).font(.hubot(20, 700))
            if let detail {
                Text(detail)
                    .font(.mona(13))
                    .foregroundStyle(Haze.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 24)
    }
}

extension AppRecord {
    func matches(_ search: String) -> Bool {
        displayName.localizedCaseInsensitiveContains(search) || package.localizedCaseInsensitiveContains(search)
    }
}
