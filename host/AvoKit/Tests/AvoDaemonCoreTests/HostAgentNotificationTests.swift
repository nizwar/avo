import Testing
@testable import AvoDaemonCore

@Suite struct HostAgentNotificationTests {
    /// `cmd notification get` on Android 17 (Avo Hello's notification, setAutoCancel(true)).
    private static let hello = """
        NotificationRecord(0x03368062: pkg=com.avodroid.hello user=UserHandle{0} id=25339 tag=null importance=3 \
        key=0|com.avodroid.hello|25339|null|10124: Notification(channel=hello shortcut=null contentView=null vibrate=null \
        sound=null defaults=0 flags=AUTO_CANCEL color=0x00000000 vis=PRIVATE))
          flags=AUTO_CANCEL
          originalFlags=AUTO_CANCEL
            when=1792264925339/1792264925339
                android.title=String (Avo Hello)
                android.text=String (Ketukan-ke-3)
        """

    /// Opening a notification dismisses it when its app says so (FLAG_AUTO_CANCEL).
    @Test func autoCancelComesFromTheFlags() throws {
        let info = try #require(HostAgent.parseNotification(Self.hello))
        #expect(info.package == "com.avodroid.hello")
        #expect(info.title == "Avo Hello")
        #expect(info.text == "Ketukan-ke-3")
        #expect(info.postedAt == 1792264925339)
        #expect(info.autoCancel)
        #expect(!info.ongoing)

        func flags(_ value: String) throws -> HostAgent.NotificationInfo {
            try #require(HostAgent.parseNotification("NotificationRecord(0x1: pkg=com.avodroid.hello importance=3)\n  flags=\(value)\n"))
        }
        #expect(try flags("0x10").autoCancel)
        #expect(try flags("16").autoCancel)
        #expect(try flags("ONGOING_EVENT|AUTO_CANCEL").autoCancel)
        #expect(try !flags("0x0").autoCancel)
        #expect(try !flags("ONGOING_EVENT|CAN_COLORIZE").autoCancel)
        #expect(try flags("ONGOING_EVENT|CAN_COLORIZE").ongoing)
        // No flags in the dump: opening it dismisses it.
        #expect(HostAgent.parseNotification("NotificationRecord(0x1: pkg=com.avodroid.hello importance=3)\n")?.autoCancel == true)
    }
}
