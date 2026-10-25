import AvoKit
import SwiftUI

/// Notifications from Android apps, newest first and stacked per app, as in
/// Notification Center (where macOS also shows them once the user allows
/// Avo). Clicking one opens its app; they go away as on a phone: dismissed
/// here (the button on hover, Clear All) or in Notification Center, they are
/// dismissed in Android too, and opening one dismisses it when its app says so.
///
/// A lazy stack rather than a List: a List on macOS kept the heights of rows
/// that arrived quickly at a few points, cutting off their title and text.
struct NotificationsPane: View {
    @Environment(ControlPanelModel.self) private var model
    /// Apps whose stack is spread out.
    @State private var expanded: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            MacNotificationsBanner()
            if model.notifications.isEmpty {
                ContentUnavailableView {
                    Label("No notifications", systemImage: "bell.slash")
                } description: {
                    Text("Notifications from Android apps show up here while Android runs.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(NotificationGroup.grouping(model.notifications)) { group in
                            NotificationStack(group: group, icon: model.icons[group.package],
                                              expanded: expanded.contains(group.package) && group.notifications.count > 1) {
                                if expanded.contains(group.package) {
                                    expanded.remove(group.package)
                                } else {
                                    expanded.insert(group.package)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .windowDragArea()
            }
        }
        // The banner stays at the top, also above an empty list.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Also while it is on: the banner comes back if the user turns it off.
        .refreshesMacNotifications()
        .toolbar {
            ToolbarItem {
                Button("Clear All") { model.clearNotifications() }
                    .disabled(model.notifications.isEmpty)
                    .help("Dismisses every notification here, in Notification Center and in Android")
            }
        }
    }
}

/// One app's notifications: its newest on top of the others until clicked,
/// then all of them with a header.
private struct NotificationStack: View {
    @Environment(ControlPanelModel.self) private var model
    let group: NotificationGroup
    let icon: NSImage?
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        if group.notifications.count == 1 {
            NotificationCard(notification: group.newest, icon: icon, open: { model.open(group.newest) },
                             dismiss: { model.dismiss([group.newest]) })
        } else if expanded {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(group.appName).font(.headline)
                    Spacer()
                    Button("Show Less", action: toggle)
                    Button("Clear") { model.dismiss(group.notifications) }
                        .help("Dismisses all of \(group.appName)’s notifications")
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
                ForEach(group.notifications) { notification in
                    NotificationCard(notification: notification, icon: icon, open: { model.open(notification) },
                                     dismiss: { model.dismiss([notification]) })
                }
            }
        } else {
            // A stack: the newest, the others peeking out below it.
            NotificationCard(notification: group.newest, icon: icon, more: group.notifications.count - 1,
                             open: toggle, dismiss: { model.dismiss(group.notifications) })
                .background(alignment: .bottom) {
                    CardShape().padding(.horizontal, 10).offset(y: 6)
                }
                .padding(.bottom, 6)
        }
    }
}

/// Icon, app, time, title and text at their natural height; the dismiss
/// button shows on hover, as in Notification Center.
private struct NotificationCard: View {
    let notification: AndroidNotification
    let icon: NSImage?
    /// The stack's others (a collapsed stack: clicking spreads it out).
    var more = 0
    let open: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.badge").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(notification.appName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(notification.postedAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                if !notification.title.isEmpty {
                    Text(notification.title).font(.headline).lineLimit(2)
                }
                if !notification.body.isEmpty {
                    Text(notification.body).lineLimit(4)
                }
                if more > 0 {
                    Text("\(more) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            // Natural height, however fast rows arrive.
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { CardShape() }
        .overlay(alignment: .topLeading) {
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.secondary, .background)
            }
            .buttonStyle(.plain)
            .offset(x: -7, y: -7)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .help(more > 0 ? Text("Dismiss All") : Text("Dismiss"))
            .accessibilityLabel(more > 0 ? Text("Dismiss All") : Text("Dismiss"))
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
        .onHover { hovering = $0 }
        .help(more > 0 ? Text("Show all \(more + 1)") : Text("Open \(notification.appName)"))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: more > 0 ? Text("Dismiss All") : Text("Dismiss"), dismiss)
    }
}

private struct CardShape: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.background.secondary)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator)
            }
    }
}
