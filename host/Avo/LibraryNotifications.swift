import AvoKit
import SwiftUI

/// Library › Notifications: Android's notifications, newest first and one
/// card per app, as Notification Center stacks them. The newest app's card
/// is open with its text and actions; the others are one line until shown.
/// Opening one opens its app; dismissing here dismisses it in Notification
/// Center and Android too (the model's calls, as before).
struct LibraryNotifications: View {
    @Environment(ControlPanelModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filter: NotificationFilter = .all
    /// Apps whose notifications are spread out.
    @State private var expanded: Set<String> = []
    /// Clear All: the cards leave one after another, then the list empties.
    @State private var clearing = false
    /// The chosen filter's light, which slides between the chips.
    @Namespace private var chipHighlight

    var body: some View {
        let groups = NotificationGroup.grouping(model.notifications.filter { filter.includes($0, model: model) })
        // Cards arrive from just above and leave shrinking a little.
        let card: AnyTransition = reduceMotion ? .opacity
            : .asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6)),
                          removal: .opacity.combined(with: .scale(scale: 0.96)))
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center, spacing: 14) {
                Text("Notifications")
                    .font(.hubot(30, 750))
                    .tracking(-0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityAddTraits(.isHeader)
                Button("Clear All") { clearAll(groups.count) }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 36, fontSize: 13, horizontalPadding: 16))
                    .disabled(model.notifications.isEmpty || clearing)
                    .help("Dismisses every notification here, in Notification Center and in Android")
            }
            HStack(spacing: 8) {
                ForEach(NotificationFilter.allCases) { option in
                    FilterChip(title: option == .all ? Text("All · \(model.notifications.count)") : Text(option.title),
                               selected: filter == option, id: option.rawValue, highlight: chipHighlight) { filter = option }
                }
            }
            .animation(Haze.Motion.animation(Haze.Motion.slide, reduceMotion: reduceMotion), value: filter)
            MacNotificationsBanner()
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            ZStack(alignment: .top) {
                if groups.isEmpty {
                    LibraryEmpty(symbol: "bell.slash", title: filter == .all ? "No notifications" : "Nothing here",
                                 detail: filter == .all ? "Notifications from Android apps show up here while Android runs." : nil)
                        .transition(.opacity)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 20) {
                            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                                Group {
                                    if expanded.contains(group.package) && group.notifications.count > 1 {
                                        ExpandedGroup(group: group, icon: model.icons[group.package]) { expanded.remove(group.package) }
                                    } else if index == 0 {
                                        LeadCard(group: group, icon: model.icons[group.package]) { expanded.insert(group.package) }
                                    } else {
                                        LineCard(notification: group.newest, icon: model.icons[group.package], more: group.notifications.count - 1,
                                                 showAll: { expanded.insert(group.package) },
                                                 dismiss: { model.dismiss(group.notifications) })
                                    }
                                }
                                .transition(card)
                                // Clear All: one after another, quickly.
                                .opacity(clearing ? 0 : 1)
                                .offset(x: clearing && !reduceMotion ? 28 : 0)
                                .animation(Haze.Motion.list.delay(Double(min(index, 10)) * 0.035), value: clearing)
                            }
                        }
                        .padding(.bottom, 56)
                    }
                    .windowDragArea()
                    .scrollIndicators(.hidden)
                    .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: groups.map(\.id))
            .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: groups.map(\.notifications.count))
            .animation(Haze.Motion.animation(Haze.Motion.list, reduceMotion: reduceMotion), value: expanded)
        }
        .padding(.horizontal, 40)
        .padding(.top, 26)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .refreshesMacNotifications()
    }

    /// The cards on screen leave in a quick stagger, then everything is
    /// dismissed (at once with Reduce Motion).
    private func clearAll(_ cards: Int) {
        guard !reduceMotion, cards > 0 else {
            withAnimation(Haze.Motion.fade) { model.clearNotifications() }
            return
        }
        clearing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220 + min(cards, 10) * 35))
            withAnimation(Haze.Motion.fade) {
                model.clearNotifications()
                clearing = false
            }
        }
    }
}

enum NotificationFilter: String, CaseIterable, Identifiable {
    case all, games, apps, system

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .all: "All"
        case .games: "Games"
        case .apps: "Apps"
        case .system: "System"
        }
    }

    @MainActor func includes(_ notification: AndroidNotification, model: ControlPanelModel) -> Bool {
        let app = model.apps.first { $0.package == notification.package }
        switch self {
        case .all: return true
        case .games: return app.map(model.isGame) ?? false
        case .apps: return app.map { !$0.systemApp && !model.isGame($0) } ?? false
        case .system: return app?.systemApp ?? true
        }
    }
}

private struct FilterChip: View {
    let title: Text
    let selected: Bool
    let id: String
    /// The chips' one light, which slides to the chosen one.
    let highlight: Namespace.ID
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            title
                .font(.mona(13, selected ? 700 : 400))
                .foregroundStyle(selected ? Haze.onAccent : (hovering ? Haze.text : Haze.textSecondary))
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background {
                    ZStack {
                        Capsule().fill(Haze.field)
                        Capsule().fill(Haze.text.opacity(hovering && !selected ? 0.05 : 0))
                        if selected {
                            Capsule().fill(Haze.accent)
                                .matchedGeometryEffect(id: reduceMotion ? id : "chip", in: highlight)
                        }
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(HazeCardButtonStyle())
        .hazeHover($hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The newest app: its name, how many, its newest notification in full,
/// and Open.
private struct LeadCard: View {
    @Environment(ControlPanelModel.self) private var model
    let group: NotificationGroup
    let icon: NSImage?
    let showAll: () -> Void

    var body: some View {
        let newest = group.newest
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                AppIconView(icon: icon, size: 34, cornerRadius: 9)
                (Text(group.appName).font(.mona(14, 600))
                 + (group.notifications.count > 1 ? Text(verbatim: " · ").foregroundStyle(Haze.textTertiary)
                    + Text("\(group.notifications.count) new").font(.mona(14)).foregroundStyle(Haze.textTertiary) : Text(verbatim: "")))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                TimeAgo(date: newest.postedAt)
                DismissButton(all: group.notifications.count > 1) { model.dismiss(group.notifications) }
            }
            VStack(alignment: .leading, spacing: 4) {
                if !newest.title.isEmpty {
                    Text(newest.title).font(.mona(15, 600)).lineLimit(2)
                }
                if !newest.body.isEmpty {
                    Text(newest.body).font(.mona(14)).foregroundStyle(Haze.textSecondary).lineLimit(4)
                }
            }
            .padding(.leading, 46)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Open") { model.open(newest) }
                    .buttonStyle(HazeButtonStyle(kind: .primary, height: 38, fontSize: 13, horizontalPadding: 16))
                if group.notifications.count > 1 {
                    Button("Show All") { showAll() }
                        .buttonStyle(HazeButtonStyle(kind: .secondary, height: 38, fontSize: 13, horizontalPadding: 16))
                }
            }
            .padding(.leading, 46)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// One notification on a line: its title, the app and text, when, and
/// (for a stack) "and 8 more" with Show All.
private struct LineCard: View {
    @Environment(ControlPanelModel.self) private var model
    let notification: AndroidNotification
    let icon: NSImage?
    var more = 0
    let showAll: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconView(icon: icon, size: 34, cornerRadius: 9)
            VStack(alignment: .leading, spacing: 2) {
                (Text(notification.title.isEmpty ? notification.appName : notification.title).font(.mona(14, 600))
                 + (more > 0 ? Text(verbatim: " · ").foregroundStyle(Haze.textTertiary)
                    + Text("and \(more) more").font(.mona(14)).foregroundStyle(Haze.textTertiary) : Text(verbatim: "")))
                    .lineLimit(1)
                Text(detail).font(.mona(13)).foregroundStyle(Haze.textSecondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if more > 0 {
                Button("Show All", action: showAll)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 12))
            } else {
                TimeAgo(date: notification.postedAt)
            }
            DismissButton(all: more > 0, action: dismiss)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(hovering ? Haze.text.opacity(0.065) : Haze.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .hazeCard(hovering: hovering, cornerRadius: 18, lifts: false)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onTapGesture { more > 0 ? showAll() : model.open(notification) }
        .hazeHover($hovering)
        .help(more > 0 ? Text("Show all \(more + 1)") : Text("Open \(notification.appName)"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// "Garena Delta Force · Claim them before Sunday."
    private var detail: String {
        let text = notification.title.isEmpty ? "" : notification.body
        return text.isEmpty ? notification.appName : "\(notification.appName) · \(text)"
    }
}

/// An app's notifications spread out, each on its line.
private struct ExpandedGroup: View {
    @Environment(ControlPanelModel.self) private var model
    let group: NotificationGroup
    let icon: NSImage?
    let showLess: () -> Void
    /// The stack spreads out one line after another.
    @State private var spread = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text(group.appName).font(.mona(15, 600))
                Spacer()
                Button("Show Less", action: showLess)
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 12))
                Button("Clear") { model.dismiss(group.notifications) }
                    .buttonStyle(HazeButtonStyle(kind: .secondary, height: 30, fontSize: 12, horizontalPadding: 12))
                    .help("Dismisses all of \(group.appName)’s notifications")
            }
            .padding(.horizontal, 4)
            ForEach(Array(group.notifications.enumerated()), id: \.element.id) { index, notification in
                LineCard(notification: notification, icon: icon, showAll: {}, dismiss: { model.dismiss([notification]) })
                    .hazeEntrance(spread, delay: Double(min(index, 8)) * 0.03, rise: -8)
            }
        }
        .onAppear { spread = true }
    }
}

private struct TimeAgo: View {
    let date: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(formatAgo(date, now: context.date))
                .font(.mona(12))
                .foregroundStyle(Haze.textTertiary)
                .lineLimit(1)
        }
    }
}

private struct DismissButton: View {
    var all = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
        }
        .buttonStyle(HazeIconButtonStyle(size: 28, fill: Haze.button, foreground: Haze.textSecondary))
        .help(all ? Text("Dismiss All") : Text("Dismiss"))
        .accessibilityLabel(all ? Text("Dismiss All") : Text("Dismiss"))
    }
}
