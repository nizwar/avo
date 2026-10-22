import AvoKit
import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// The mouse wheel's scroll mode: where it is kept, how notches read, what
/// Automatic mode learns, and how a burst goes out.
@Suite struct WheelScrollingTests {
    /// Content in a 720 × 640 region on the vertical scroll grid (18 × 160
    /// cells of 40 × 4 pixels): bands of "text" a few rows high, every cell
    /// its own gray. `offset`: cell rows the content scrolled up (negative:
    /// down).
    private func list(offset: Int) -> ScreenSample {
        func hash(_ value: Int) -> Int {
            var x = UInt64(bitPattern: Int64(value)) &* 0x9E37_79B9_7F4A_7C15
            x ^= x >> 29
            x = x &* 0xBF58_476D_1CE4_E5B9
            x ^= x >> 32
            return Int(x & 0xFFFF)
        }
        let columns = 18, rows = 160
        var cells = [UInt8](repeating: 245, count: columns * rows)
        for row in 0..<rows {
            let line = row + offset
            guard hash(Int((Double(line) / 3).rounded(.down))) % 3 != 0 else { continue }
            for column in 0..<columns { cells[row * columns + column] = UInt8(hash(line &* 131 &+ column) % 200) }
        }
        return ScreenSample(width: columns * 40, height: rows * 4, columns: columns, rows: rows, cells: cells)
    }

    // MARK: The setting

    @Test func theModeIsKeptPerAppOverTheDefault() throws {
        let names = (0..<3).map { "com.avodroid.tests.scroll.\($0).\(UUID().uuidString)" }
        let app = try #require(UserDefaults(suiteName: names[0]))
        let shared = try #require(UserDefaults(suiteName: names[1]))
        let otherApp = try #require(UserDefaults(suiteName: names[2]))
        defer { for name in names { UserDefaults.standard.removePersistentDomain(forName: name) } }
        let settings = ScrollModeSettings(app: app, shared: shared)
        #expect(settings.mode == .automatic && settings.appChoice == nil && settings.defaultMode == .automatic)

        settings.setAppMode(.swipe)
        #expect(app.string(forKey: ScrollModeSettings.appKey) == "swipe")
        #expect(settings.mode == .swipe)
        // A new default: this app keeps its own choice, another app follows.
        settings.setDefaultMode(.mouseWheel)
        #expect(shared.string(forKey: ScrollModeSettings.defaultKey) == "mouseWheel")
        let other = ScrollModeSettings(app: otherApp, shared: shared)
        #expect(settings.mode == .swipe && other.mode == .mouseWheel)
        // Choosing the default's mode is following the default again.
        settings.setAppMode(.mouseWheel)
        #expect(app.object(forKey: ScrollModeSettings.appKey) == nil)
        #expect(settings.appChoice == nil && settings.mode == .mouseWheel)
        settings.setDefaultMode(.automatic)
        #expect(shared.object(forKey: ScrollModeSettings.defaultKey) == nil)
        #expect(settings.mode == .automatic && other.mode == .automatic)
        // A value from a newer Avo reads as no choice.
        app.set("sideways", forKey: ScrollModeSettings.appKey)
        #expect(settings.appChoice == nil && settings.mode == .automatic)
    }

    // MARK: Notches

    @Test func shiftTurnsTheWheelSideways() {
        #expect(WheelNotch.lines(deltaX: 0, deltaY: 2, shift: true) == (2, 0))
        #expect(WheelNotch.lines(deltaX: 0, deltaY: -1, shift: false) == (0, -1))
        // macOS turned it already.
        #expect(WheelNotch.lines(deltaX: -1, deltaY: 0, shift: true) == (-1, 0))
        #expect(WheelNotch.axis(dx: 2, dy: 0) == .horizontal && WheelNotch.axis(dx: 0.5, dy: -1) == .vertical)
        #expect(WheelNotch.direction(dx: 0, dy: -1, axis: .vertical) == -1)
        #expect(WheelNotch.direction(dx: 3, dy: 0, axis: .horizontal) == 1)
    }

    @Test func scrollEventsUseAndroidsAxes() {
        // Content moving down is the wheel rolled away: AXIS_VSCROLL > 0;
        // content moving right is AXIS_HSCROLL < 0.
        let event = WheelNotch.scrollEvent(displayID: 3, x: 10, y: 20, dx: 1, dy: 2)
        #expect(event == ScrollEvent(displayID: 3, x: 10, y: 20, horizontal: -1, vertical: 2))
    }

    // MARK: Learning

    @Test func theRouteLearnsSwipesAndTriesScrollEventsAgain() {
        var route = WheelRoute()
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 0, screenChanged: false) == .scrollEvents(fallback: true))
        route.learn(.swipesWork, x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 10)
        #expect(route.way == .swipes)
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 20, screenChanged: false) == .swipe)
        // Between 3 s and the retry, a screen change would try again.
        #expect(!route.wantsScreenCheck(at: 11) && route.wantsScreenCheck(at: 20) && !route.wantsScreenCheck(at: 41))
        // After a while: scroll events again.
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 41, screenChanged: false) == .scrollEvents(fallback: true))
        // Still only swipes: twice as long until the next try.
        route.learn(.swipesWork, x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 41.5)
        #expect(route.retryInterval == 60)
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 90, screenChanged: false) == .swipe)
        // Another screen of the app: try now.
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 90, screenChanged: true) == .scrollEvents(fallback: true))
        route.learn(.scrollEventsWork, x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 90.2)
        #expect(route.way == .scrollEvents && route.retryInterval == WheelRoute.firstRetry)
        // The wait grows to five minutes at most.
        for step in 0..<10 { route.learn(.swipesWork, x: 0, y: 0, axis: .vertical, direction: 1, at: 100 + Double(step)) }
        #expect(route.retryInterval == WheelRoute.longestRetry)
    }

    @Test func whereNothingMovedThereIsNoSwipeForAWhile() {
        var route = WheelRoute()
        // The end of a list: neither scroll events nor a swipe moved it.
        route.learn(.nothingMoved, x: 0.5, y: 0.7, axis: .vertical, direction: -1, at: 1)
        #expect(route.way == .scrollEvents)
        #expect(route.plan(x: 0.55, y: 0.65, axis: .vertical, direction: -1, at: 2, screenChanged: false) == .scrollEvents(fallback: false))
        // The other way, or somewhere else, is another matter.
        #expect(route.plan(x: 0.5, y: 0.7, axis: .vertical, direction: 1, at: 2, screenChanged: false) == .scrollEvents(fallback: true))
        #expect(route.plan(x: 0.5, y: 0.2, axis: .vertical, direction: -1, at: 2, screenChanged: false) == .scrollEvents(fallback: true))
        #expect(route.plan(x: 0.5, y: 0.7, axis: .horizontal, direction: -1, at: 2, screenChanged: false) == .scrollEvents(fallback: true))
        // It wears off, and another screen clears it at once.
        #expect(route.plan(x: 0.5, y: 0.7, axis: .vertical, direction: -1, at: 9.5, screenChanged: false) == .scrollEvents(fallback: true))
        route.learn(.nothingMoved, x: 0.5, y: 0.7, axis: .vertical, direction: -1, at: 10)
        #expect(route.plan(x: 0.5, y: 0.7, axis: .vertical, direction: -1, at: 11, screenChanged: true) == .scrollEvents(fallback: true))
        // Where swipes are the way, such a place gets scroll events only.
        route.learn(.swipesWork, x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 12)
        route.learn(.nothingMoved, x: 0.5, y: 0.9, axis: .vertical, direction: 1, at: 13)
        #expect(route.plan(x: 0.5, y: 0.9, axis: .vertical, direction: 1, at: 14, screenChanged: false) == .scrollEvents(fallback: false))
        #expect(route.plan(x: 0.5, y: 0.5, axis: .vertical, direction: 1, at: 14, screenChanged: false) == .swipe)
    }

    @Test func aProbeSeesTheContentSlideItsWay() {
        var probe = WheelProbe(x: 360, y: 640, axis: .vertical, direction: 1, fallback: true)
        probe.start(with: list(offset: 0), at: 0)
        probe.noteSent(dx: 0, dy: 1)
        // A frame the scroll did not reach yet, then one it did: content 128 pixels down.
        #expect(probe.look(list(offset: 0)) == nil)
        #expect(probe.look(list(offset: -32)) == .scrolled)
        #expect(probe.stage == .finished)
        #expect(probe.tick(at: 1) == nil)
    }

    @Test func aProbeReplaysWhatWentOutWhenNothingSlidItsWay() {
        var probe = WheelProbe(x: 360, y: 640, axis: .vertical, direction: 1, fallback: true)
        probe.start(with: list(offset: 0), at: 0)
        probe.noteSent(dx: 0, dy: 1)
        probe.noteSent(dx: 0, dy: 0.5)
        // Something slid the other way (an animation): not this scroll.
        #expect(probe.look(list(offset: 20)) == nil)
        #expect(probe.tick(at: 0.2) == nil)
        #expect(probe.tick(at: WheelProbe.window) == .replay(dx: 0, dy: 1.5))
        #expect(probe.stage == .swipe)
        #expect(probe.swipeEnded(followed: true) == .swipesWork)
        var again = WheelProbe(x: 360, y: 640, axis: .vertical, direction: 1, fallback: true)
        again.start(with: list(offset: 0), at: 0)
        again.noteSent(dx: 0, dy: 1)
        _ = again.tick(at: 1)
        // Neither moved it: the end of a list.
        #expect(again.swipeEnded(followed: false) == .nothingMoved)
    }

    @Test func aProbeWithoutFallbackOrPictureSendsScrollEventsOnly() {
        var dead = WheelProbe(x: 0, y: 0, axis: .vertical, direction: -1, fallback: false)
        dead.start(with: list(offset: 0), at: 0)
        dead.noteSent(dx: 0, dy: -1)
        #expect(dead.tick(at: 1) == .nothingMoved)
        var blind = WheelProbe(x: 0, y: 0, axis: .vertical, direction: -1, fallback: true)
        blind.start(with: nil, at: 0)
        #expect(blind.stage == .finished && blind.tick(at: 1) == nil)
    }

    @Test func theWatchSeesTheContentFollowTheFinger() {
        var watch = SwipeWatch(axis: .vertical, before: list(offset: 0))
        // The finger went 200 pixels up; the frame shows the content only 16 up: not yet.
        let early = watch.look(list(offset: 4), displacement: -200)
        #expect(!early)
        // The other way is no following.
        let wrongWay = watch.look(list(offset: -30), displacement: -200)
        #expect(!wrongWay)
        // 120 pixels up: it follows.
        let following = watch.look(list(offset: 30), displacement: -200)
        #expect(following)
        #expect(watch.followed)
    }

    @Test func theWatchSeesASlideBetweenLooksPastTheRegion() {
        var watch = SwipeWatch(axis: .vertical, before: list(offset: 0))
        // 360 pixels up already: further than the region can show against the picture before.
        let first = watch.look(list(offset: 90), displacement: -400)
        #expect(!first)
        // The next look slid another 120 pixels with the finger: it follows.
        let second = watch.look(list(offset: 120), displacement: -520)
        #expect(second)
    }

    @Test func theWatchsVerdictWaitsForTheFramesToShow() {
        var watch = SwipeWatch(axis: .vertical, before: list(offset: 0), since: 10)
        // Too soon to tell: a finger lifting now lifts with ACTION_UP.
        #expect(watch.verdict(at: 10.1) == nil)
        // Nothing followed in time: ACTION_CANCEL.
        #expect(watch.verdict(at: 10.2) == false)
        watch.look(list(offset: 30), displacement: -200)
        #expect(watch.verdict(at: 10.05) == true && watch.verdict(at: 11) == true)
    }

    // MARK: Bursts

    @Test func mouseWheelModeSendsScrollEvents() {
        var scroller = WheelScroller(width: 720, height: 1280)
        #expect(scroller.notch(dx: 0, dy: 1, x: 100, y: 200, mode: .mouseWheel, touches: true, fingerDown: false, at: 0)
            == [.scroll(x: 100, y: 200, dx: 0, dy: 1)])
        #expect(scroller.notch(dx: -2, dy: 0, x: 100, y: 200, mode: .mouseWheel, touches: true, fingerDown: true, at: 0.1)
            == [.scroll(x: 100, y: 200, dx: -2, dy: 0)])
        #expect(!scroller.isBusy)
    }

    @Test func swipeModeMovesTheFingerWhenTouchesAreFree() {
        var scroller = WheelScroller(width: 720, height: 1280)
        #expect(scroller.notch(dx: 0, dy: -1, x: 100, y: 200, mode: .swipe, touches: true, fingerDown: false, at: 0)
            == [.swipe(x: 100, y: 200, dx: 0, dy: -1)])
        // A click or the key mapping holds the touches: a scroll event instead.
        #expect(scroller.notch(dx: 0, dy: -1, x: 100, y: 200, mode: .swipe, touches: false, fingerDown: false, at: 1)
            == [.scroll(x: 100, y: 200, dx: 0, dy: -1)])
    }

    @Test func automaticKeepsScrollEventsWhereTheContentSlides() {
        var scroller = WheelScroller(width: 720, height: 1280)
        // The first notch waits for the picture before it.
        #expect(scroller.notch(dx: 0, dy: 1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0)
            == [.samplePicture(x: 360, y: 640, axis: .vertical)])
        #expect(scroller.notch(dx: 0, dy: 1, x: 360, y: 645, mode: .automatic, touches: true, fingerDown: false, at: 0.004).isEmpty)
        #expect(scroller.pictureBefore(list(offset: 0), at: 0.005)
            == [.scroll(x: 360, y: 640, dx: 0, dy: 1), .scroll(x: 360, y: 645, dx: 0, dy: 1)])
        #expect(scroller.isWatching)
        scroller.look(list(offset: -32), at: 0.06)
        #expect(!scroller.isWatching && scroller.route.way == .scrollEvents)
        // The rest of the burst goes out as scroll events, and nothing is replayed.
        #expect(scroller.notch(dx: 0, dy: 1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0.1)
            == [.scroll(x: 360, y: 640, dx: 0, dy: 1)])
        #expect(scroller.tick(at: 1).isEmpty)
    }

    @Test func automaticSwipesWhereScrollEventsDoNothingAndKeepsSwiping() {
        var scroller = WheelScroller(width: 720, height: 1280)
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0)
            == [.samplePicture(x: 360, y: 640, axis: .vertical)])
        #expect(scroller.pictureBefore(list(offset: 0), at: 0.01) == [.scroll(x: 360, y: 640, dx: 0, dy: -1)])
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0.05)
            == [.scroll(x: 360, y: 640, dx: 0, dy: -1)])
        // A ViewPager: frames come, nothing slides.
        scroller.look(list(offset: 0), at: 0.1)
        #expect(scroller.tick(at: 0.2).isEmpty)
        // Replayed as one swipe from where the burst began.
        #expect(scroller.tick(at: 0.24) == [.swipe(x: 360, y: 640, dx: 0, dy: -2)])
        // The burst's next notches join the finger.
        #expect(scroller.notch(dx: 0, dy: -1, x: 370, y: 600, mode: .automatic, touches: true, fingerDown: true, at: 0.26)
            == [.swipe(x: 370, y: 600, dx: 0, dy: -1)])
        scroller.swipeEnded(followed: true, at: 0.7)
        #expect(scroller.route.way == .swipes)
        // From now on this app swipes at once.
        #expect(scroller.notch(dx: 0, dy: 1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 1.5)
            == [.swipe(x: 360, y: 640, dx: 0, dy: 1)])
        // Notches after the finger lifted, in the same burst: swipes too.
        #expect(scroller.notch(dx: 0, dy: 1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 1.7)
            == [.swipe(x: 360, y: 640, dx: 0, dy: 1)])
    }

    @Test func theEndOfAListIsNoReasonToSwitch() {
        var scroller = WheelScroller(width: 720, height: 1280)
        func burst(_ dy: Double, at time: Double) -> [WheelScroller.Command] {
            var commands = scroller.notch(dx: 0, dy: dy, x: 360, y: 900, mode: .automatic, touches: true, fingerDown: false, at: time)
            commands += scroller.pictureBefore(list(offset: 0), at: time + 0.005)
            scroller.look(list(offset: 0), at: time + 0.1)
            commands += scroller.tick(at: time + 0.3)
            return commands
        }
        // At the end: scroll events do nothing, so a swipe tries, and only stretches.
        #expect(burst(-1, at: 0).last == .swipe(x: 360, y: 900, dx: 0, dy: -1))
        scroller.swipeEnded(followed: false, at: 0.6)
        #expect(scroller.route.way == .scrollEvents)
        // Further notches there that way: scroll events only, no swipe.
        #expect(burst(-1, at: 1) == [.samplePicture(x: 360, y: 900, axis: .vertical), .scroll(x: 360, y: 900, dx: 0, dy: -1)])
        // Back the other way the list scrolls with scroll events.
        var back = scroller.notch(dx: 0, dy: 1, x: 360, y: 900, mode: .automatic, touches: true, fingerDown: false, at: 2)
        back += scroller.pictureBefore(list(offset: 0), at: 2.005)
        scroller.look(list(offset: -20), at: 2.1)
        back += scroller.tick(at: 2.4)
        #expect(back == [.samplePicture(x: 360, y: 900, axis: .vertical), .scroll(x: 360, y: 900, dx: 0, dy: 1)])
        #expect(scroller.route.way == .scrollEvents)
    }

    @Test func anotherScreenTriesScrollEventsAgain() {
        var scroller = WheelScroller(width: 720, height: 1280)
        _ = scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0)
        _ = scroller.pictureBefore(list(offset: 0), at: 0.01)
        _ = scroller.tick(at: 0.3)
        scroller.swipeEnded(followed: true, at: 0.6)
        #expect(scroller.route.way == .swipes)
        // Soon after: swipes, no questions.
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 2)
            == [.swipe(x: 360, y: 640, dx: 0, dy: -1)])
        // Later the window compares the screen first; the notch waits.
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 5)
            == [.checkScreen])
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 650, mode: .automatic, touches: true, fingerDown: false, at: 5.01).isEmpty)
        #expect(scroller.screenChecked(false, at: 5.02)
            == [.swipe(x: 360, y: 640, dx: 0, dy: -1), .swipe(x: 360, y: 650, dx: 0, dy: -1)])
        // Another screen: scroll events are tried, and work there.
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 9)
            == [.checkScreen])
        #expect(scroller.screenChecked(true, at: 9.01) == [.samplePicture(x: 360, y: 640, axis: .vertical)])
        #expect(scroller.pictureBefore(list(offset: 0), at: 9.02) == [.scroll(x: 360, y: 640, dx: 0, dy: -1)])
        scroller.look(list(offset: 32), at: 9.1)
        #expect(scroller.route.way == .scrollEvents)
    }

    @Test func theKeyMappingsTouchesGetScrollEvents() {
        var scroller = WheelScroller(width: 720, height: 1280)
        #expect(scroller.notch(dx: 0, dy: 1, x: 1, y: 2, mode: .automatic, touches: false, fingerDown: false, at: 0)
            == [.scroll(x: 1, y: 2, dx: 0, dy: 1)])
        #expect(!scroller.isBusy)
    }

    @Test func withoutAnAnswerTheNotchesGoOutAnyway() {
        var scroller = WheelScroller(width: 720, height: 1280)
        _ = scroller.notch(dx: 0, dy: 1, x: 1, y: 2, mode: .automatic, touches: true, fingerDown: false, at: 0)
        _ = scroller.notch(dx: 0, dy: 1, x: 1, y: 2, mode: .automatic, touches: true, fingerDown: false, at: 0.05)
        #expect(scroller.isBusy)
        #expect(scroller.tick(at: 0.1).isEmpty)
        #expect(scroller.tick(at: 0.3) == [.scroll(x: 1, y: 2, dx: 0, dy: 1), .scroll(x: 1, y: 2, dx: 0, dy: 1)])
        #expect(!scroller.isBusy)
        // A late answer changes nothing.
        #expect(scroller.pictureBefore(list(offset: 0), at: 0.4).isEmpty)
        #expect(scroller.notch(dx: 0, dy: 1, x: 1, y: 2, mode: .automatic, touches: true, fingerDown: false, at: 0.32)
            == [.scroll(x: 1, y: 2, dx: 0, dy: 1)])
    }

    @Test func cancelEndsTheBurstButKeepsWhatWasLearned() {
        var scroller = WheelScroller(width: 720, height: 1280)
        _ = scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 0)
        _ = scroller.pictureBefore(list(offset: 0), at: 0.01)
        _ = scroller.tick(at: 0.3)
        scroller.swipeEnded(followed: true, at: 0.6)
        _ = scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 1)
        scroller.cancel()
        #expect(!scroller.isBusy && scroller.burst == nil && scroller.route.way == .swipes)
        #expect(scroller.notch(dx: 0, dy: -1, x: 360, y: 640, mode: .automatic, touches: true, fingerDown: false, at: 1.1)
            == [.swipe(x: 360, y: 640, dx: 0, dy: -1)])
    }
}
