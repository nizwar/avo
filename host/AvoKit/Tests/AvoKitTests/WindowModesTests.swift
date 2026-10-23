import CoreGraphics
import Foundation
import Testing
@testable import AvoKit

/// Picture in Picture's size and place, and the per-app window modes.
@Suite struct WindowModesTests {
    /// A 14-inch MacBook Pro's visible area below the menu bar (and above a hidden Dock).
    private let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)

    @Test func theMiniWindowHasThePicturesShape() {
        let phone = PictureInPicture.size(aspect: 1080.0 / 2340, longSide: nil, visible: laptop)
        #expect(phone == CGSize(width: 199, height: 431))
        let game = PictureInPicture.size(aspect: 16.0 / 9, longSide: nil, visible: laptop)
        #expect(game == CGSize(width: 390, height: 220))
        // About 6% of the screen either way.
        for size in [phone, game] {
            #expect(abs(size.width * size.height / (laptop.width * laptop.height) - 0.06) < 0.002)
        }
    }

    @Test func theUsersSizeStaysWithinLimits() {
        // As it was left, longer side first.
        #expect(PictureInPicture.size(aspect: 0.5, longSide: 300, visible: laptop) == CGSize(width: 150, height: 300))
        // Never more than half the screen along a side…
        #expect(PictureInPicture.size(aspect: 0.5, longSide: 2000, visible: laptop) == CGSize(width: 236, height: 473))
        #expect(PictureInPicture.size(aspect: 3, longSide: 2000, visible: laptop) == CGSize(width: 756, height: 252))
        // …nor so small that the app cannot be seen.
        #expect(PictureInPicture.size(aspect: 0.5, longSide: 40, visible: laptop) == CGSize(width: 120, height: 240))
        // No shape yet: square.
        #expect(PictureInPicture.size(aspect: 0, longSide: 200, visible: laptop) == CGSize(width: 200, height: 200))
    }

    @Test func itSitsInACornerOfTheScreen() {
        let size = CGSize(width: 200, height: 400)
        let screen = CGRect(x: 100, y: 50, width: 1512, height: 945)
        #expect(PictureInPicture.frame(size: size, corner: .bottomRight, visible: screen) == CGRect(x: 1396, y: 66, width: 200, height: 400))
        #expect(PictureInPicture.frame(size: size, corner: .topLeft, visible: screen) == CGRect(x: 116, y: 579, width: 200, height: 400))
        // Dragged somewhere: the nearest corner takes it.
        #expect(PictureInPicture.nearestCorner(to: CGRect(x: 300, y: 600, width: 200, height: 300), in: screen) == .topLeft)
        #expect(PictureInPicture.nearestCorner(to: CGRect(x: 1000, y: 100, width: 200, height: 300), in: screen) == .bottomRight)
        #expect(PictureInPicture.nearestCorner(to: CGRect(x: 1000, y: 500, width: 200, height: 300), in: screen) == .topRight)
    }

    @Test func eachAppRemembersItsModes() throws {
        let suite = "dev.avo.tests.windowmodes.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WindowModeSettings(store: store)
        #expect(!settings.keepOnTop)
        #expect(settings.corner == .bottomRight)
        #expect(settings.longSide == nil)
        settings.keepOnTop = true
        settings.corner = .topLeft
        settings.longSide = 320
        let again = WindowModeSettings(store: store)
        #expect(again.keepOnTop && again.corner == .topLeft && again.longSide == 320)
        again.keepOnTop = false
        again.longSide = nil
        #expect(store.object(forKey: WindowModeSettings.keepOnTopKey) == nil && store.object(forKey: WindowModeSettings.longSideKey) == nil)
    }

    /// An app follows the Control Panel's app bar style until it has its own.
    @Test func anAppMayHaveItsOwnAppBarStyle() throws {
        let suite = "dev.avo.tests.appbar.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = WindowModeSettings(store: store)
        #expect(settings.appBarStyle == nil)
        settings.appBarStyle = .phone
        #expect(WindowModeSettings(store: store).appBarStyle == .phone)
        // One a newer Avo wrote (or an older test build's Minimal) reads as none of its own.
        store.set("minimal", forKey: WindowModeSettings.appBarStyleKey)
        #expect(settings.appBarStyle == nil)
        settings.appBarStyle = nil
        #expect(store.object(forKey: WindowModeSettings.appBarStyleKey) == nil)
    }

    /// Closing a game's window asks first until Don't Ask Again (or Settings) turns it off.
    @Test func quittingAGameAsksUntilToldNotTo() throws {
        let suite = "dev.avo.tests.quit.\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: suite))
        defer { store.removePersistentDomain(forName: suite) }
        let settings = QuitSettings(store: store)
        #expect(settings.asksBeforeQuittingGames)
        settings.asksBeforeQuittingGames = false
        #expect(!QuitSettings(store: store).asksBeforeQuittingGames)
        settings.asksBeforeQuittingGames = true
        #expect(store.object(forKey: QuitSettings.askKey) == nil)
    }
}
