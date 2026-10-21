import AvoKit
import CoreGraphics
import Foundation
import Testing

/// Translate Screen's plates through a scroll (ScreenFollow), on a made-up
/// phone screen: a header that stays, and a list of items, each with a line
/// of "text" (dark marks, as wide as its words) on white.
@Suite struct ScreenFollowTests {
    struct Screen {
        static let width = 1080, height = 2400
        static let header = 220.0
        static let item = 180.0
        /// How far the list scrolled: content moved up by this many pixels.
        var scroll = 0.0
        /// Another app's screen: other words everywhere.
        var other = false

        /// The text line of `index`: where it starts and how wide it is.
        func words(_ index: Int) -> (x: Double, width: Double) {
            let seed = (index &* 2_654_435_761 &+ (other ? 97 : 0)) & 0xFFFF
            return (40 + Double(seed % 5) * 12, 220 + Double(seed % 620))
        }

        func gray(_ x: Double, _ y: Double) -> Double {
            if y < Self.header {
                // A title bar's title.
                let inTitle = y > 90 && y < 140 && x > 60 && x < 420 && Int(x / 14) % 4 != 0
                return inTitle ? 250 : 40
            }
            let content = y - Self.header + scroll
            let index = Int((content / Self.item).rounded(.down))
            let inItem = content - Double(index) * Self.item
            let line = words(index)
            // A divider between items, and the item's line of text.
            if inItem < 2 { return 200 }
            let marks = inItem > 70 && inItem < 108 && x > line.x && x < line.x + line.width
                && Int((x - line.x) / 15 + Double(index % 3)) % 5 != 0
            return marks ? 30 : 255
        }

        /// The text line of `index` in frame pixels (as Vision would box it).
        func rect(of index: Int) -> CGRect {
            let line = words(index)
            return CGRect(x: line.x, y: Self.header + Double(index) * Self.item - scroll + 70, width: line.width, height: 38)
        }

        /// The frame on `ScreenSample.stripGrid`: each cell the average of
        /// its pixels (every other row and column).
        func strip() -> ScreenSample {
            let grid = ScreenSample.stripGrid(width: Self.width, height: Self.height)
            let cellWidth = Double(Self.width) / Double(grid.columns), cellHeight = Double(Self.height) / Double(grid.rows)
            var sums = [Double](repeating: 0, count: grid.columns * grid.rows)
            var counts = [Double](repeating: 0, count: grid.columns * grid.rows)
            var y = 0.5
            while y < Double(Self.height) {
                let row = min(grid.rows - 1, Int(y / cellHeight))
                var x = 0.5
                while x < Double(Self.width) {
                    let column = min(grid.columns - 1, Int(x / cellWidth))
                    sums[row * grid.columns + column] += gray(x, y)
                    counts[row * grid.columns + column] += 1
                    x += 2
                }
                y += 1
            }
            let cells = zip(sums, counts).map { UInt8(($0 / max($1, 1)).rounded()) }
            return ScreenSample(width: Self.width, height: Self.height, columns: grid.columns, rows: grid.rows, cells: cells)
        }
    }

    @Test func theStripHasFineRowsAndCoarseColumns() {
        #expect(ScreenSample.stripGrid(width: 1080, height: 2400) == (27, 320))
        #expect(ScreenSample.stripGrid(width: 720, height: 1280) == (18, 320))
        #expect(ScreenSample.stripGrid(width: 2400, height: 1080) == (32, 270))
    }

    /// A slow scroll: every look slides the list a little, the plates follow
    /// it, and the header's do not need to.
    @Test func platesFollowTheTextThroughAScroll() throws {
        var screen = Screen()
        var follow = ScreenFollow()
        follow.start(from: screen.strip())
        let read = (1...6).map { screen.rect(of: $0) }
        #expect(follow.moved(read[0]) == nil, "nothing moved yet")
        for step in [37.0, 41, 52, 44] {
            screen.scroll += step
            follow.look(at: screen.strip())
        }
        #expect(!follow.lost)
        #expect(abs(follow.offset + screen.scroll) <= 6, "slid \(follow.offset), the list \(-screen.scroll)")
        for (index, rect) in zip(1...6, read) {
            let moved = try #require(follow.moved(rect), "item \(index)")
            #expect(abs(moved.minY - screen.rect(of: index).minY) <= 6)
        }
    }

    /// A fling: a few looks, each sliding the list further than an item.
    @Test func aFastScrollMovesNoPlateOntoOtherText() {
        var screen = Screen()
        var follow = ScreenFollow()
        follow.start(from: screen.strip())
        let read = (1...10).map { screen.rect(of: $0) }
        for step in [140.0, 310, 260, 190] {
            screen.scroll += step
            follow.look(at: screen.strip())
        }
        var followed = 0
        for (index, rect) in zip(1...10, read) {
            guard let moved = follow.moved(rect) else { continue }
            followed += 1
            #expect(abs(moved.minY - screen.rect(of: index).minY) <= 6, "item \(index) must show over its own text")
        }
        // The list moved 900 pixels: items 6 to 10 are still on screen.
        #expect(followed >= 4)
    }

    @Test func aPlateScrolledOffTheFrameGoes() throws {
        var screen = Screen()
        var follow = ScreenFollow()
        follow.start(from: screen.strip())
        let first = screen.rect(of: 0)
        let later = screen.rect(of: 5)
        for _ in 0..<4 {
            screen.scroll += 60
            follow.look(at: screen.strip())
        }
        #expect(follow.moved(first) == nil, "under the header now")
        #expect(try #require(follow.moved(later)).minY < later.minY)
    }

    /// Another screen: nothing moves onto its text, and after something
    /// else than a slide nothing moves until the next read.
    @Test func anotherScreenEndsIt() throws {
        var screen = Screen()
        var follow = ScreenFollow()
        follow.start(from: screen.strip())
        let rect = screen.rect(of: 3)
        screen.scroll += 50
        follow.look(at: screen.strip())
        let moved = try #require(follow.moved(rect))
        #expect(abs(moved.minY - screen.rect(of: 3).minY) <= 3, "each plate finds its own place")
        // The same list layout with other words can pass for a slide; no plate moves onto it.
        screen.other = true
        follow.look(at: screen.strip())
        for index in 0...10 { #expect(follow.moved(Screen().rect(of: index)) == nil) }
        // A fade to white: no plate shows over it either.
        let faded = Screen()
        var fading = ScreenFollow()
        fading.start(from: faded.strip())
        fading.look(at: ScreenSample(width: Screen.width, height: Screen.height, columns: 27, rows: 320,
                                     cells: [UInt8](repeating: 255, count: 27 * 320)))
        for index in 0...10 { #expect(fading.moved(faded.rect(of: index)) == nil) }
        // The next read starts again.
        fading.start(from: faded.strip())
        #expect(!fading.lost && fading.offset == 0)
    }

    @Test func aDifferentSizeEndsIt() {
        var follow = ScreenFollow()
        follow.start(from: Screen().strip())
        follow.look(at: ScreenSample(width: 2400, height: 1080, columns: 32, rows: 270, cells: [UInt8](repeating: 255, count: 32 * 270)))
        #expect(follow.lost)
        var none = ScreenFollow()
        none.start(from: nil)
        #expect(none.lost)
    }
}
