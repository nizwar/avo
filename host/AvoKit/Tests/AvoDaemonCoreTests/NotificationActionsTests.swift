import AvoKit
import AvoProtocol
import AvoTestSupport
import Foundation
import Testing
@testable import AvoDaemonCore

/// A notification's buttons on the Mac: Reply answers from the banner, and
/// the others do what tapping them in Android's shade does.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NotificationActionsTests {
    private static let chat = "com.avodroid.chat"
    private static let key = "0|com.avodroid.chat|7|null|10124"

    /// `cmd notification get` on Android 17: a message with Reply and Mark as read.
    private static let dump = """
        NotificationRecord(0x0ab76e68: pkg=com.avodroid.chat user=UserHandle{0} id=7 tag=null importance=3 \
        key=0|com.avodroid.chat|7|null|10124: Notification(channel=chat shortcut=null contentView=null vibrate=null \
        sound=null defaults=0 flags=0 color=0x00000000 actions=2 vis=PRIVATE))
          flags=0
            when=1792264925339/1792264925339
                android.title=String (Alice)
                android.text=String (are you there?)
            actions={
                [0] "Reply" -> PendingIntent{2de281: PendingIntentRecord{6458171 com.avodroid.chat broadcastIntent}}
                [1] "Mark as read" -> PendingIntent{f52ef26: PendingIntentRecord{c5f7318 com.avodroid.chat broadcastIntent}}
              }
        """

    @Test func theDumpCountsTheButtons() throws {
        #expect(try #require(HostAgent.parseNotification(Self.dump)).actions == 2)
        #expect(HostAgent.parseNotification("NotificationRecord(0x1: pkg=com.avodroid.chat importance=3 flags=0 vis=PRIVATE)\n")?.actions == 0)
    }

    /// The helper's `actions` (guest/clipboard Notifications.java), as Android 17 printed it.
    @Test func theHelperSaysWhatEachButtonTakes() {
        let output = """
            {"key":"0|com.avodroid.chat|7|null|10124","actions":[{"index":0,"title":"Reply","reply":true,"hint":"Message"},\
            {"index":1,"title":"Mark as read","reply":false}]}
            {"key":"0|com.avodroid.chat|8|null|10124","actions":[]}
            not json
            """
        let buttons = HostAgent.parseNotificationActions(output)
        let first = buttons[Self.key] ?? []
        #expect(first.map(\.title) == ["Reply", "Mark as read"])
        #expect(first.map(\.index) == [0, 1])
        #expect(first.map(\.reply) == [true, false])
        #expect(first.map(\.replyHint) == ["Message", ""])
        #expect(buttons["0|com.avodroid.chat|8|null|10124"] == [])
        #expect(buttons.count == 2)
    }

    @Test func buttonsPressedOnTheMacReachAndroid() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app(Self.chat, label: "Chat")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)

        var reply = Avo_V1_NotificationAction()
        reply.index = 0
        reply.title = "Reply"
        reply.reply = true
        reply.replyHint = "Message"
        var read = Avo_V1_NotificationAction()
        read.index = 1
        read.title = "Mark as read"
        var notification = Avo_V1_Notification()
        notification.package = Self.chat
        notification.key = Self.key
        notification.title = "Alice"
        notification.body = "are you there?"
        notification.actions = [reply, read]
        await harness.agent.emit(.notification(notification))
        // Notification Center gets the buttons with it.
        #expect(await eventually { harness.notifications.posts.first?.actions == [reply, read] })

        harness.notifications.press(Self.key, button: 0, reply: "On my way 🥑")
        harness.notifications.press(Self.key, button: 1)
        let performed: () async -> [Avo_V1_PerformNotificationAction] = {
            await harness.agent.requests { if case .performNotificationAction(let action) = $0 { action } else { nil } }
        }
        #expect(await eventually { await performed().count == 2 })
        let actions = await performed().sorted { $0.index < $1.index }
        #expect(actions.map(\.key) == [Self.key, Self.key])
        #expect(actions.map(\.replyText) == ["On my way 🥑", ""])
    }
}

/// What Android plays, in the Mac's Now Playing.
@Suite(.serialized, .timeLimit(.minutes(1))) struct NowPlayingTests {
    private static let music = "com.avodroid.music"

    /// The helper's `media watch` lines (guest/clipboard Media.java), as Android 17 printed them.
    @Test func helperLinesBecomeNowPlaying() throws {
        let playing = try #require(HostAgent.nowPlaying(fromLine: """
            media {"package":"com.avodroid.music","title":"Fake Song","artist":"Avo Band","album":"Tests","durationMs":180000,\
            "next":true,"previous":false,"seek":true,"state":"playing","speed":1,"positionMs":30006,"artworkJpeg":"\\/9j\\/4AAQ"}
            """))
        #expect(playing.package == Self.music)
        #expect(playing.title == "Fake Song")
        #expect(playing.artist == "Avo Band")
        #expect(playing.album == "Tests")
        #expect(playing.durationMs == 180000)
        #expect(playing.positionMs == 30006)
        #expect(playing.speed == 1)
        #expect(playing.state == .playing)
        #expect(playing.canNext && !playing.canPrevious && playing.canSeek)
        #expect(playing.artworkChanged)
        #expect(playing.artworkJpeg == Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]))

        // Without artwork: the last one holds.
        let paused = try #require(HostAgent.nowPlaying(fromLine: """
            media {"package":"com.avodroid.music","title":"Fake Song","artist":"","album":"","durationMs":0,\
            "next":false,"previous":false,"seek":false,"state":"paused","speed":0,"positionMs":33000}
            """))
        #expect(paused.state == .paused)
        #expect(!paused.artworkChanged)
        // Gone: "" says so.
        #expect(HostAgent.nowPlaying(fromLine: #"media {"package":"p","title":"","artist":"","album":"","durationMs":0,"next":false,"previous":false,"seek":false,"state":"buffering","speed":0,"positionMs":0,"artworkJpeg":""}"#)?.artworkChanged == true)

        #expect(HostAgent.nowPlaying(fromLine: "media none") == Avo_V1_NowPlaying())
        #expect(HostAgent.nowPlaying(fromLine: "ready") == nil)
        #expect(HostAgent.nowPlaying(fromLine: "media {broken") == nil)
    }

    @Test func commandsBecomeHelperLines() {
        func line(_ command: Avo_V1_MediaCommand.Command, at position: Int64 = 0) -> String? {
            var media = Avo_V1_MediaCommand()
            media.command = command
            media.positionMs = position
            return HostAgent.mediaCommandLine(media)
        }
        #expect(line(.toggle) == "toggle")
        #expect(line(.play) == "play")
        #expect(line(.next) == "next")
        #expect(line(.previous) == "previous")
        #expect(line(.seek, at: 42000) == "seek 42000")
        #expect(line(.seek, at: -5) == "seek 0")
        #expect(line(.unspecified) == nil)
    }

    @Test func androidsPlayerReachesTheMacAndBack() async throws {
        let harness = try Harness(apps: [FakeBridgeAgent.app(Self.music, label: "Music")])
        defer { harness.cleanUp() }
        await harness.core.start()
        let (panel, _) = await harness.connect(.controlPanel)
        try await harness.core.startVM(client: panel)
        #expect(await harness.waitForShims(1))

        var playing = Avo_V1_NowPlaying()
        playing.package = Self.music
        playing.title = "Fake Song"
        playing.state = .playing
        playing.artworkChanged = true
        playing.artworkJpeg = Data([1, 2, 3])
        await harness.agent.emit(.nowPlaying(playing))
        #expect(await eventually { harness.nowPlaying.shown.last?.playing?.title == "Fake Song" })
        #expect(harness.nowPlaying.shown.last?.appName == "Music")
        #expect(harness.nowPlaying.shown.last?.artwork == Data([1, 2, 3]))

        // Paused, artwork unchanged: the Mac keeps showing it.
        var paused = playing
        paused.state = .paused
        paused.artworkChanged = false
        paused.artworkJpeg = Data()
        await harness.agent.emit(.nowPlaying(paused))
        #expect(await eventually { harness.nowPlaying.shown.last?.playing?.state == .paused })
        #expect(harness.nowPlaying.shown.last?.artwork == Data([1, 2, 3]))

        // The play/pause key.
        harness.nowPlaying.command(.toggle)
        let commands: () async -> [Avo_V1_MediaCommand.Command] = {
            await harness.agent.requests { if case .mediaCommand(let media) = $0 { media.command } else { nil } }
        }
        #expect(await eventually { await commands() == [.toggle] })

        // Nothing plays any more.
        await harness.agent.emit(.nowPlaying(Avo_V1_NowPlaying()))
        #expect(await eventually { harness.nowPlaying.shown.count >= 3 && harness.nowPlaying.shown.last?.playing == nil })

        // Android stops: Now Playing lets go.
        await harness.agent.emit(.nowPlaying(playing))
        #expect(await eventually { harness.nowPlaying.shown.last?.playing != nil })
        try await harness.core.stopVM(client: panel)
        #expect(await eventually { harness.nowPlaying.shown.last?.playing == nil })
    }
}
