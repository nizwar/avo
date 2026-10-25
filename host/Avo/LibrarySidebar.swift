import AvoKit
import SwiftUI

/// The Library's sidebar: Avo, the sections (games and apps together in
/// Library, under its tabs), the apps running now, and Settings at the
/// bottom (its own window).
struct LibrarySidebar: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The selection's highlight, which slides from row to row.
    @Namespace private var selection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                AvoMark().frame(width: 26, height: 26)
                Text(verbatim: "Avo")
                    .font(.hubot(19, 700))
                    .tracking(-0.2)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(LibrarySection.allCases) { section in
                SidebarRow(title: section.title, symbol: section.symbol, selected: router.page == nil && router.section == section,
                           badge: section == .notifications ? model.notifications.count : 0, highlight: selection) {
                    router.show(section)
                }
            }

            let running = model.runningApps
            if !running.isEmpty {
                Text("Running")
                    .textCase(.uppercase)
                    .font(.hazeMono(11))
                    .tracking(1.2)
                    .foregroundStyle(Haze.sectionLabel)
                    .padding(.horizontal, 12)
                    .padding(.top, 22)
                    .padding(.bottom, 8)
                    .accessibilityAddTraits(.isHeader)
                    .transition(.opacity)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(running) { app in
                            RunningRow(app: app, icon: model.icons[app.package])
                                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: -12)))
                        }
                    }
                }
                .windowDragArea()
                .scrollIndicators(.never)
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
            SidebarRow(title: "Settings", symbol: "gearshape", selected: false, badge: 0, turnsOnHover: true) {
                openWindow(id: SettingsWindow.id)
            }
        }
        .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: router.section)
        .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: model.runningApps.map(\.package))
        .padding(.top, 54)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        // 236 points of rows inside 14-point margins.
        .frame(width: 264)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Haze.sidebar)
    }
}

private struct SidebarRow: View {
    let title: LocalizedStringKey
    let symbol: String
    let selected: Bool
    let badge: Int
    /// The highlight shared by the section rows (it slides between them).
    var highlight: Namespace.ID?
    /// Settings: the gear turns as the pointer arrives.
    var turnsOnHover = false
    let action: () -> Void
    @State private var hovering = false
    /// Bumped as the row becomes selected (or the gear is hovered): its symbol bounces once.
    @State private var nudge = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        Button(action: action) {
            HStack(spacing: 12) {
                symbolImage
                    .font(.system(size: 15, weight: .regular))
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.mona(14, selected ? 600 : 400))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if badge > 0 {
                    Text(badge, format: .number)
                        .font(.mona(12, 700))
                        .foregroundStyle(Haze.onAccent)
                        .contentTransition(.numericText(value: Double(badge)))
                        .padding(.horizontal, 6)
                        .frame(minWidth: 22, minHeight: 20)
                        .background(Haze.accent, in: Capsule())
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.5)))
                }
            }
            .foregroundStyle(selected ? Haze.accentText : Haze.textSecondary)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                ZStack {
                    shape.fill(Haze.text.opacity(hovering && !selected ? 0.05 : 0))
                    if selected {
                        if let highlight {
                            shape.fill(Haze.selection)
                                .matchedGeometryEffect(id: reduceMotion ? AnyHashable(symbol) : AnyHashable("selection"), in: highlight)
                        } else {
                            shape.fill(Haze.selection)
                        }
                    }
                }
            }
            .contentShape(shape)
        }
        .buttonStyle(HazeCardButtonStyle())
        .hazeHover($hovering)
        .onChange(of: selected) { _, now in
            if now && !reduceMotion { nudge += 1 }
        }
        .onChange(of: hovering) { _, now in
            if now && turnsOnHover && !reduceMotion { nudge += 1 }
        }
        .animation(Haze.Motion.count, value: badge)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var symbolImage: some View {
        if turnsOnHover {
            Image(systemName: symbol).symbolEffect(.rotate, value: nudge)
        } else {
            Image(systemName: symbol).symbolEffect(.bounce.down, value: nudge)
        }
    }
}

/// A running app: a click brings its window, holding opens its page, a
/// right click shows its menu (AppTileInteraction.swift).
private struct RunningRow: View {
    let app: AppRecord
    let icon: NSImage?
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(icon: icon, size: 22, cornerRadius: 6)
                .scaleEffect(hovering && !reduceMotion ? 1.1 : 1)
            Text(app.displayName)
                .font(.mona(13))
                .foregroundStyle(hovering ? Haze.text : Haze.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            RunningDot()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Haze.text.opacity(hovering ? 0.05 : 0), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .appTileActions(app, cornerRadius: 10)
        .hazeHover($hovering)
        .help(app.package)
    }
}

/// An app's icon as Android draws it, or a quiet tile while there is none.
/// The tile shimmers for a few seconds while the icon is probably on its
/// way; the icon fades in over it.
struct AppIconView: View {
    let icon: NSImage?
    var size: CGFloat
    var cornerRadius: CGFloat
    /// Icons load right after the apps: shimmer this long at most.
    @State private var waiting = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92)))
            } else {
                shape
                    .fill(Haze.text.opacity(0.08))
                    .overlay {
                        Image(systemName: "app.dashed")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(Haze.textTertiary)
                    }
                    .hazeSheen(waiting, in: shape, intensity: 0.1, period: 1.5)
                    .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .animation(.easeOut(duration: 0.35), value: icon != nil)
        .task {
            guard icon == nil else { return }
            try? await Task.sleep(for: .seconds(4))
            waiting = false
        }
        .accessibilityHidden(true)
    }
}
