import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// Notifications go away as on a phone: dismissed in Avo's list or in
/// Notification Center, they are dismissed in Android too.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NotificationDismissTests {
    private static let hello = "dev.avo.hello"

    private static func key(_ n: Int) -> String { "0|\(hello)|\(n)|null|10124" }

    private static func post(_ n: Int, on harness: Harness) async {
        var notification = Avo_V1_Notification()
        notification.package = hello
        notification.key = key(n)
        notification.title = "Avo Hello"
        notification.body = "Ketukan ke-\(n)"
        await harness.agent.emit(.notification(notification))
    }

    /// What the Control Panel lists now (its latest list).
    private static func listed(_ client: RecordingClient) -> [String]? {
        for event in client.events.reversed() {
            if case .notifications(let list) = event { return list.map(\.body) }
        }
        return nil
    }

    private static func dismissed(_ harness: Harness) async -> [String] {
        await harness.agent.requests { if case .dismissNotification(let d) = $0 { d.key } else { nil } }
    }

    @Test func dismissedNotificationsGoAwayEverywhere() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app(Self.hello, label: "Avo Hello")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        for n in 1...3 { await Self.post(n, on: harness) }
        #expect(await eventually { Self.listed(events) == ["Ketukan ke-3", "Ketukan ke-2", "Ketukan ke-1"] })

        // A row's dismiss button.
        try await harness.core.dismissNotifications([Self.key(2)], client: panel)
        #expect(Self.listed(events) == ["Ketukan ke-3", "Ketukan ke-1"])
        #expect(harness.notifications.removed.contains(Self.key(2)))
        #expect(await eventually { await Self.dismissed(harness) == [Self.key(2)] })

        // Closed in Notification Center.
        harness.notifications.closeInNotificationCenter(Self.key(3))
        #expect(await eventually { Self.listed(events) == ["Ketukan ke-1"] })
        #expect(await eventually { await Self.dismissed(harness) == [Self.key(2), Self.key(3)] })

        // Clear All.
        try await harness.core.clearNotifications(client: panel)
        #expect(Self.listed(events) == [])
        #expect(await eventually { await Self.dismissed(harness) == [Self.key(2), Self.key(3), Self.key(1)] })

        // Only the Control Panel dismisses.
        let (shim, _) = await harness.connect(.shim(package: Self.hello))
        await #expect(throws: AvoError.unauthorizedCaller) { try await harness.core.dismissNotifications([Self.key(1)], client: shim) }
    }

    /// The app's Dock badge: its App Shim hears how many notifications
    /// Android shows, on connecting and as that changes.
    @Test func appShimsHearTheirNotificationCount() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app(Self.hello, label: "Avo Hello")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        for n in 1...2 { await Self.post(n, on: harness) }
        #expect(await eventually { await harness.core.notificationCount(of: Self.hello) == 2 })

        let (_, shimEvents) = await harness.connect(.shim(package: Self.hello))
        let (_, otherEvents) = await harness.connect(.shim(package: "dev.avo.other"))
        func count() -> Int? {
            for event in shimEvents.events.reversed() {
                if case .notificationCount(Self.hello, let count) = event { return count }
            }
            return nil
        }
        #expect(await eventually { count() == 2 })

        // Posted again (updated): still one.
        await Self.post(2, on: harness)
        await Self.post(3, on: harness)
        #expect(await eventually { count() == 3 })

        // Removed in Android, and dismissed on the Mac.
        var removed = Avo_V1_NotificationRemoved()
        removed.key = Self.key(1)
        await harness.agent.emit(.notificationRemoved(removed))
        #expect(await eventually { count() == 2 })
        try await harness.core.clearNotifications(client: panel)
        #expect(count() == 0)

        // Another app's shim hears only its own count.
        #expect(!otherEvents.events.contains { if case .notificationCount(Self.hello, _) = $0 { true } else { false } })
    }

    /// An app with a window: Android opens the notification there (and drops
    /// it when the app made it go away on opening); reopening the shim only
    /// brings the window to the front.
    @Test func openingANotificationOfAnOpenAppAsksAndroid() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app(Self.hello, label: "Avo Hello")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, events) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(1))
        await Self.post(7, on: harness)
        #expect(await eventually { Self.listed(events) == ["Ketukan ke-7"] })

        let (shim, shimEvents) = await harness.connect(.shim(package: Self.hello))
        let display = try await harness.core.openDisplay(OpenDisplayRequest(package: Self.hello, width: 800, height: 1600, dpi: 320),
                                                         client: shim)
        #expect(await shimEvents.wait { $0 == .displayReady(displayID: display) } != nil)
        try await harness.core.openNotification(key: Self.key(7), client: panel)
        #expect(await eventually {
            let opened: [Avo_V1_OpenNotification] = await harness.agent.requests { if case .openNotification(let o) = $0 { o } else { nil } }
            return opened.map(\.key) == [Self.key(7)] && opened.first?.displayID == display
        })
        // Android's removal takes it off the list.
        var removed = Avo_V1_NotificationRemoved()
        removed.key = Self.key(7)
        await harness.agent.emit(.notificationRemoved(removed))
        #expect(await eventually { Self.listed(events) == [] })
    }
}
