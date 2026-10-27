import Testing
@testable import AvoDaemonCore

@Suite struct HostAgentTests {
    /// `am stack list` on Android 17 (trimmed).
    static let stacks = """
        RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
          taskId=7: com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}
        RootTask id=20 bounds=[0,0][704,924] displayId=3 userId=0
          taskId=20: com.avodroid.hello/com.avodroid.hello.MainActivity bounds=[0,0][704,924] userId=0 visible=true topActivity=ComponentInfo{com.avodroid.hello/com.avodroid.hello.MainActivity}
        RootTask id=21 bounds=[0,0][408,892] displayId=4 userId=0
          taskId=21: com.example.game/com.example.game.Main bounds=[0,0][408,892] userId=0 visible=false topActivity=ComponentInfo{com.example.game/com.example.game.Main}
        """

    @Test func findsAPackagesTaskOnADisplay() {
        #expect(HostAgent.hasTask(of: "com.avodroid.hello", onDisplay: 3, in: Self.stacks))
        #expect(!HostAgent.hasTask(of: "com.avodroid.hello", onDisplay: 0, in: Self.stacks))
        #expect(!HostAgent.hasTask(of: "com.avodroid", onDisplay: 3, in: Self.stacks))
    }

    @Test func aDisplayWithOnlyHiddenTasksIsEmpty() {
        #expect(HostAgent.hasVisibleTask(onDisplay: 3, in: Self.stacks))
        #expect(!HostAgent.hasVisibleTask(onDisplay: 4, in: Self.stacks))
        #expect(!HostAgent.hasVisibleTask(onDisplay: 5, in: Self.stacks))
    }

    @Test func aForceStoppedAppsWindowIsEmptyWhileItsNewTaskWaitsOnAndroidsOwnScreen() {
        // `flutter run`: force-stop, install, `am start`. The old task stays in the window, hidden and
        // without activities; the new one starts on display 0 and moves into that window.
        let stacks = """
            RootTask id=134 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=134: id.suruhkami/id.suruhkami.MainActivity bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{id.suruhkami/id.suruhkami.MainActivity}
            RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=7: com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher bounds=[0,0][720,1280] userId=0 visible=false topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}
            RootTask id=133 bounds=[0,0][416,936] displayId=6 userId=0
              taskId=133: id.suruhkami/id.suruhkami.MainActivity bounds=[0,0][416,936] userId=0 visible=false
            """
        #expect(!HostAgent.hasVisibleTask(onDisplay: 6, in: stacks))
        #expect(HostAgent.visibleTasks(onDisplay: 0, in: stacks).map(\.id) == [134])
        #expect(HostAgent.visibleRootTasks(onDisplay: 0, in: stacks).map(\.root) == [134])
    }

    @Test func findsAppsInFrontOfAndroidsOwnScreen() {
        let stacks = """
            RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=7: com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher bounds=[0,0][720,1280] userId=0 visible=false topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}
            RootTask id=37 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=37: com.avodroid.hello/com.avodroid.hello.MainActivity bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.avodroid.hello/com.avodroid.hello.MainActivity}
            RootTask id=20 bounds=[0,0][704,924] displayId=3 userId=0
              taskId=20: com.example.game/com.example.game.Main bounds=[0,0][704,924] userId=0 visible=true topActivity=ComponentInfo{com.example.game/com.example.game.Main}
            """
        let front = HostAgent.visibleTasks(onDisplay: 0, in: stacks)
        #expect(front.map(\.id) == [37])
        #expect(front.map(\.package) == ["com.avodroid.hello"])
    }

    @Test func theHomeScreenIsNeverAnAppToOpen() {
        // Android locked after it starts: its home is Settings' FallbackHome, which is no app to give a window.
        let stacks = """
            RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
             configuration={1.0 ?mcc0mnc [en_ID] ldltr sw480dp port winConfig={ mBounds=Rect(0, 0 - 720, 1280) mWindowingMode=fullscreen mActivityType=home mAlwaysOnTop=undefined}
              taskId=2: com.android.settings/com.android.settings.FallbackHome bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.android.settings/com.android.settings.FallbackHome}
            RootTask id=37 bounds=[0,0][720,1280] displayId=0 userId=0
             configuration={1.0 ?mcc0mnc [en_ID] ldltr sw480dp port winConfig={ mBounds=Rect(0, 0 - 720, 1280) mWindowingMode=fullscreen mActivityType=standard mAlwaysOnTop=undefined}
              taskId=37: com.android.settings/com.android.settings.Settings bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.android.settings/com.android.settings.Settings}
            """
        // Settings opened by something else still gets its window; its FallbackHome does not.
        #expect(HostAgent.visibleTasks(onDisplay: 0, in: stacks).map(\.id) == [37])
        #expect(HostAgent.visibleRootTasks(onDisplay: 0, in: stacks).map(\.root) == [37])
    }

    @Test func findsTheTaskToMoveIntoAWindow() {
        let stacks = """
            RootTask id=1 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=7: com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher bounds=[0,0][720,1280] userId=0 visible=false topActivity=ComponentInfo{com.android.launcher3/com.android.launcher3.uioverrides.QuickstepLauncher}
            RootTask id=43 bounds=[0,0][720,1280] displayId=0 userId=0
              taskId=43: com.avodroid.hello/com.avodroid.hello.MainActivity bounds=[0,0][720,1280] userId=0 visible=true topActivity=ComponentInfo{com.avodroid.hello/com.avodroid.hello.MainActivity}
            RootTask id=20 bounds=[0,0][704,924] displayId=3 userId=0
              taskId=20: com.example.game/com.example.game.Main bounds=[0,0][704,924] userId=0 visible=true topActivity=ComponentInfo{com.example.game/com.example.game.Main}
            """
        #expect(HostAgent.rootTask(of: "com.avodroid.hello", onDisplay: 0, in: stacks) == 43)
        // Only tasks on Android's own screen are taken; a window's task stays.
        #expect(HostAgent.rootTask(of: "com.example.game", onDisplay: 0, in: stacks) == nil)
        #expect(HostAgent.rootTask(of: "com.avodroid", onDisplay: 0, in: stacks) == nil)
    }

    @Test func findsAppsThatLandedInAnotherAppsWindow() {
        let stacks = """
            RootTask id=50 bounds=[0,0][1160,800] displayId=3 userId=0
              taskId=50: id.suruhkami/com.suru.passenger.MainActivity bounds=[0,0][1160,800] userId=0 visible=true topActivity=ComponentInfo{id.suruhkami/com.suru.passenger.MainActivity}
            RootTask id=46 bounds=[0,0][1160,800] displayId=3 userId=0
              taskId=46: com.avodroid.hello/com.avodroid.hello.MainActivity bounds=[0,0][1160,800] userId=0 visible=false topActivity=ComponentInfo{com.avodroid.hello/com.avodroid.hello.MainActivity}
            """
        let tasks = HostAgent.visibleRootTasks(onDisplay: 3, in: stacks)
        #expect(tasks.map(\.root) == [50])
        #expect(tasks.map(\.package) == ["id.suruhkami"])
    }

    @Test func sendsTheWheelAsAndroidsMouseScroll() {
        #expect(HostAgent.scrollCommand(display: 7, x: 640.4, y: 360, horizontal: 0, vertical: -2)
            == "input mouse -d 7 scroll 640 360 --axis VSCROLL,-2.000")
        #expect(HostAgent.scrollCommand(display: 3, x: 10, y: 20, horizontal: 1.5, vertical: 1)
            == "input mouse -d 3 scroll 10 20 --axis VSCROLL,1.000 --axis HSCROLL,1.500")
    }

    @Test func stopsTheThreadHALOnlyWhereTheImageHasIt() {
        // Its simulated radio needs an eth1 the engine does not have.
        #expect(HostAgent.stopThreadHALCommand
                == "[ -n \"$(getprop init.svc.vendor.threadnetwork_hal)\" ] && setprop ctl.stop vendor.threadnetwork_hal")
    }

    /// What `content call … scan_file` prints: the file's URI in Android's media index.
    @Test func readsTheURIAFileWasIndexedUnder() {
        #expect(HostAgent.contentURI(inScanOutput: "Result: Bundle[{android.intent.extra.STREAM=content://media/external_primary/file/1000000042}]\n")
            == "content://media/external_primary/file/1000000042")
        #expect(HostAgent.contentURI(inScanOutput: "Result: Bundle[{android.intent.extra.STREAM=null}]\n") == nil)
        #expect(HostAgent.contentURI(inScanOutput: "Result: null\n") == nil)
        #expect(HostAgent.contentURI(inScanOutput: "") == nil)
    }

    /// The shell's ACTION_SEND: the stream is the data too, which `am` grants a read of.
    @Test func sharesAFileAsTheShellDoes() {
        #expect(HostAgent.shareCommand(uri: "content://media/external_primary/file/7", type: "image/png", package: "org.telegram.messenger", display: 3)
            == "am start --user 0 --display 3 -a android.intent.action.SEND -t 'image/png' -d 'content://media/external_primary/file/7' "
            + "--eu android.intent.extra.STREAM 'content://media/external_primary/file/7' --grant-read-uri-permission 'org.telegram.messenger'")
    }

    @Test func startsAppsLikeALauncher() {
        // NEW_TASK | RESET_TASK_IF_NEEDED with the launcher intent: a running task moves, it does not restart.
        #expect(HostAgent.startCommand("com.avodroid.hello/.MainActivity", display: 4)
                == "am start --display 4 -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -f 0x10200000 -n 'com.avodroid.hello/.MainActivity'")
    }

    @Test func findsRunningAppsInTheProcessList() {
        let ps = """
            NAME
            init
            system_server
            com.avodroid.hello
            com.example.game:remote
            com.example.gameplus
            """
        let running = DaemonCore.packages(inProcessList: ps, among: ["com.avodroid.hello", "com.example.game", "id.other"])
        #expect(running == ["com.avodroid.hello", "com.example.game"])
    }

    @Test func readsNotificationsFromTheShell() {
        let list = "0|com.avodroid.hello|7|null|10123\n-1|android|55|null|1000\n0|com.android.shell|1|null|2000\n"
        #expect(HostAgent.notificationKeys(in: list) == ["0|com.avodroid.hello|7|null|10123", "0|com.android.shell|1|null|2000"])
        #expect(HostAgent.package(ofNotification: "0|com.avodroid.hello|7|null|10123") == "com.avodroid.hello")
        let dump = """
            NotificationRecord(0x0d276d3a: pkg=com.avodroid.hello user=UserHandle{0} id=7 tag=null importance=4 key=0|com.avodroid.hello|7|null|10123: Notification(channel=orders flags=0x10))
              icon=Icon(typ=RESOURCE pkg=com.avodroid.hello id=0x7f010000)
              flags=16
                contentIntent=PendingIntent{1234: PendingIntentRecord{5678 com.avodroid.hello startActivity}}
                when=1792179565406/1792179565406
                    android.title=String (Pesanan baru (2))
                    android.text=String (Driver menuju lokasi Anda)
            """
        let info = HostAgent.parseNotification(dump)
        #expect(info == HostAgent.NotificationInfo(package: "com.avodroid.hello", title: "Pesanan baru (2)", text: "Driver menuju lokasi Anda",
                                                   postedAt: 1_792_179_565_406, ongoing: false, importance: 4, autoCancel: true))
        let ongoing = dump.replacingOccurrences(of: "  flags=16", with: "  flags=98")
        #expect(HostAgent.parseNotification(ongoing)?.ongoing == true)
        // Android 17 prints flag names; an automatic group summary has no text of its own.
        let summary = dump.replacingOccurrences(of: "  flags=16", with: "  flags=AUTO_CANCEL|LOCAL_ONLY|GROUP_SUMMARY|AUTOGROUP_SUMMARY|SILENT")
        #expect(HostAgent.parseNotification(summary)?.ongoing == true)
        let plain = dump.replacingOccurrences(of: "  flags=16", with: "  flags=AUTO_CANCEL")
        #expect(HostAgent.parseNotification(plain)?.ongoing == false)
    }

    @Test func readsDisplayIDs() {
        let surfaceFlinger = "Display 4619827551948147201 (HWC display 1): port=1 pnpId=GGL displayName=\"Avo\""
        #expect(HostAgent.physicalDisplayID(port: 1, in: surfaceFlinger) == "4619827551948147201")
        #expect(HostAgent.physicalDisplayID(port: 11, in: surfaceFlinger) == nil)
        let displays = #"Display id 3: DisplayInfo{"Built-in Screen", displayId 3, uniqueId "local:4619827551948147201", app 704 x 924}"#
        #expect(HostAgent.logicalDisplayID(uniqueID: "local:4619827551948147201", in: displays) == 3)
    }

    /// An unplugged scanout may be plugged again only once SurfaceFlinger
    /// itself dropped the display, not when its EDID went (the 20:03 crash).
    @Test func scanoutIsReleasedOnlyOnceAndroidDroppedTheDisplay() {
        let unique = "local:4619827124781842690"
        let primary = "Display 4619827259835644672 (HWC display 0): port=0 pnpId=GGL displayName=\"EMU_display_0\""
        let other = "Display 4619827551948147201 (HWC display 12): port=12 pnpId=GGL displayName=\"EMU_display_12\""
        let listed = "Display 4619827124781842690 (HWC display 2): port=2 pnpId=GGL displayName=\"EMU_display_2\""
        // The composer forgot it, SurfaceFlinger has not committed the removal yet.
        let forgotten = "Display 4619827124781842690 (HWC display 2): no display identification data"
        let manager = #"Display id 10: DisplayInfo{"Built-in Screen", displayId 10, uniqueId "local:4619827124781842690", app 3168 x 1440}"#
        let managerWithout = #"Display id 0: DisplayInfo{"Built-in Screen", displayId 0, uniqueId "local:4619827259835644672", app 720 x 1280}"#

        #expect(!HostAgent.displayReleased(scanout: 2, uniqueID: unique, surfaceFlinger: [primary, listed].joined(separator: "\n"),
                                           displays: manager))
        #expect(!HostAgent.displayReleased(scanout: 2, uniqueID: unique, surfaceFlinger: [primary, forgotten, other].joined(separator: "\n"),
                                           displays: manager))
        // SurfaceFlinger let go, DisplayManager has not heard yet.
        #expect(!HostAgent.displayReleased(scanout: 2, uniqueID: unique, surfaceFlinger: [primary, other].joined(separator: "\n"),
                                           displays: manager))
        #expect(HostAgent.displayReleased(scanout: 2, uniqueID: unique, surfaceFlinger: [primary, other].joined(separator: "\n"),
                                          displays: managerWithout))
        // Unknown unique id (closed while Android was adding it): SurfaceFlinger decides.
        #expect(HostAgent.displayReleased(scanout: 2, uniqueID: nil, surfaceFlinger: primary, displays: manager))
        #expect(!HostAgent.displayReleased(scanout: 2, uniqueID: nil, surfaceFlinger: forgotten, displays: ""))
        // Scanout 1 is not scanout 12.
        #expect(HostAgent.displayReleased(scanout: 1, uniqueID: nil, surfaceFlinger: other, displays: ""))
        #expect(!HostAgent.displayReleased(scanout: 12, uniqueID: nil, surfaceFlinger: "Display 1 (HWC display 12): port=12", displays: ""))
    }

    @Test func newWindowsSkipScanoutsAndroidStillHolds() {
        #expect(HostAgent.freeScanout(in: 1..<16, taken: []) == 1)
        // 1 has a window, 2 was just closed and is still leaving Android.
        #expect(HostAgent.freeScanout(in: 1..<16, taken: [1, 2]) == 3)
        #expect(HostAgent.freeScanout(in: 1..<4, taken: [1, 2, 3]) == nil)
    }
}

/// HostAgent's resize loop (`DisplayResizing.applySize`), driven by a fake
/// display that logs the commands HostAgent would send.
@Suite struct HostAgentResizeTests {
    actor FakeDisplay: DisplayResizing {
        var resizing: Set<UInt32> = []
        var resizeWaiters: [UInt32: [CheckedContinuation<Void, Never>]] = [:]
        var wanted: DisplayMode
        var applied: DisplayMode
        var log: [String] = []
        /// While set, a re-plug stops after unplugging until `release()`.
        var holdsPlug = false
        private var plugGate: CheckedContinuation<Void, Never>?

        init(_ mode: DisplayMode) {
            wanted = mode
            applied = mode
        }

        func want(_ mode: DisplayMode) { wanted = mode }
        func hold() { holdsPlug = true }
        var isHeld: Bool { plugGate != nil }
        var waiting: Int { resizeWaiters[1]?.count ?? 0 }
        func record(_ line: String) { log.append(line) }

        func release() {
            holdsPlug = false
            plugGate?.resume()
            plugGate = nil
        }

        func modes(of id: UInt32) -> (wanted: DisplayMode, applied: DisplayMode)? { (wanted, applied) }

        // Mirrors HostAgent.replug: unplug, plug at the size, then the newest density.
        func replug(_ id: UInt32, to mode: DisplayMode) async throws {
            log.append("display off")
            if holdsPlug { await withCheckedContinuation { plugGate = $0 } }
            log.append("display \(mode.width) \(mode.height)")
            applied = DisplayMode(width: mode.width, height: mode.height, dpi: wanted.dpi)
            if wanted.dpi > 0 { log.append("wm density \(wanted.dpi)") }
        }

        func applyDensity(_ id: UInt32, _ dpi: UInt32) async {
            applied.dpi = dpi
            log.append("wm density \(dpi)")
        }
    }

    @Test func densityOnceWhenSizeAndDensityChange() async throws {
        let display = FakeDisplay(DisplayMode(width: 824, height: 1784, dpi: 320))
        await display.want(DisplayMode(width: 632, height: 1374, dpi: 246))
        try await display.applySize(1)
        #expect(await display.log == ["display off", "display 632 1374", "wm density 246"])
    }

    @Test func densityOnlyAppliesLive() async throws {
        let display = FakeDisplay(DisplayMode(width: 824, height: 1784, dpi: 320))
        await display.want(DisplayMode(width: 824, height: 1784, dpi: 368))
        try await display.applySize(1)
        #expect(await display.log == ["wm density 368"])
        // Nothing left to do: no command at all.
        try await display.applySize(1)
        #expect(await display.log == ["wm density 368"])
    }

    @Test func coalescedResizeRepliesAfterReplug() async throws {
        let display = FakeDisplay(DisplayMode(width: 824, height: 1784, dpi: 320))
        await display.hold()
        await display.want(DisplayMode(width: 632, height: 1374, dpi: 246))
        let first = Task {
            try await display.applySize(1)
            await display.record("reply 1")
        }
        while await !display.isHeld { await Task.yield() }

        // A second resize arrives while the first is re-plugging.
        await display.want(DisplayMode(width: 488, height: 1052, dpi: 189))
        let second = Task {
            try await display.applySize(1)
            await display.record("reply 2")
        }
        while await display.waiting == 0 { await Task.yield() }
        #expect(await !display.log.contains { $0.hasPrefix("reply") })

        await display.release()
        try await first.value
        try await second.value
        let log = await display.log
        // The loop goes on to the newest size; both replies come after it.
        #expect(Array(log.prefix(6)) == ["display off", "display 632 1374", "wm density 189",
                                         "display off", "display 488 1052", "wm density 189"])
        #expect(Set(log.suffix(2)) == ["reply 1", "reply 2"])
        #expect(await display.applied == DisplayMode(width: 488, height: 1052, dpi: 189))
    }
}
