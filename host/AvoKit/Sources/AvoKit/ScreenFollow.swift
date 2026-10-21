import CoreGraphics
import Foundation

/// Translate Screen's plates through a scroll. `ScreenWatch` reads the
/// screen again only once it holds still, and a plate over text that moved
/// goes at once; while the text under the plates slides up or down, they
/// slide with it instead, so a translation stays on its text through the
/// scroll and only the text the scroll brings in waits for the next read.
///
/// Each look compares a strip of the frame (`ScreenSample.stripGrid`: rows of
/// about 4 pixels, a few dozen columns) with the one before
/// (`ScreenSample.motion(to:along:direction:)`, as the mouse wheel's scroll
/// watch does); the slides add up while every look is one, the same way.
/// Anything else (another screen, an animation, the stretch at the end of a
/// list, a scroll back without a pause) ends it until the next read. A plate
/// shows at its new place only where the strip there shows what was under
/// it, so a slide guessed one list item off moves no plate onto other text.
public struct ScreenFollow: Sendable {
    /// How far the content slid since the plates' frame, in frame pixels
    /// (positive: down).
    public private(set) var offset: Double = 0
    /// The slides no longer tell where the text went: no plate moves until
    /// the next read.
    public private(set) var lost = true
    /// The strip of the plates' frame, and of the frame looked at last.
    private var base: ScreenSample?
    private var last: ScreenSample?
    private var direction: Int?

    /// The mean gray difference the strip under a moved plate may show
    /// against what was under it (cells of text never sample quite the same
    /// a few pixels further).
    static let tolerance = 10.0

    public init() {}

    /// The plates on screen now were read from the frame `strip` was taken of.
    public mutating func start(from strip: ScreenSample?) {
        base = strip
        last = strip
        offset = 0
        direction = nil
        lost = strip == nil
    }

    /// The strip of the frame looked at now.
    public mutating func look(at strip: ScreenSample) {
        guard !lost, let previous = last else { return }
        last = strip
        switch previous.motion(to: strip, along: .vertical, direction: direction) {
        case .still?:
            break
        case .shifted(let pixels)?:
            offset += pixels
            direction = pixels > 0 ? 1 : -1
        case .changed?, nil:
            lost = true
        }
    }

    /// Where the plate read over `rect` (frame pixels, origin at the top
    /// left) shows now: about `offset` further, when the content slid and
    /// the strip there shows what was under it; nil otherwise (it went off
    /// the frame, or other text is there). The slides are good to half a
    /// row of the strip, so each plate finds its own place within a row of
    /// where they say, in quarter rows.
    public func moved(_ rect: CGRect) -> CGRect? {
        guard !lost, offset != 0, let base, let last else { return nil }
        let row = Double(base.height) / Double(base.rows)
        var best: (move: Double, difference: Double)?
        for step in -4...4 {
            let move = offset + Double(step) * row / 4
            let target = rect.offsetBy(dx: 0, dy: move)
            guard target.minY >= 0, target.maxY <= Double(base.height),
                  let difference = Self.difference(base, under: rect, last, under: target) else { continue }
            if best.map({ difference < $0.difference }) ?? true { best = (move, difference) }
        }
        guard let best, best.difference <= Self.tolerance else { return nil }
        return rect.offsetBy(dx: 0, dy: best.move)
    }

    /// The mean gray difference between `a`'s cells under `ra` and `b`'s
    /// under `rb` (`ra` moved up or down), `b` read between its rows where
    /// the move is not a whole number of them.
    static func difference(_ a: ScreenSample, under ra: CGRect, _ b: ScreenSample, under rb: CGRect) -> Double? {
        guard a.width == b.width, a.height == b.height, a.columns == b.columns, a.rows == b.rows,
              a.width > 0, a.height > 0 else { return nil }
        let cellWidth = Double(a.width) / Double(a.columns), cellHeight = Double(a.height) / Double(a.rows)
        let firstColumn = max(0, Int((ra.minX / cellWidth).rounded(.down)))
        let lastColumn = min(a.columns, Int((ra.maxX / cellWidth).rounded(.up)))
        let firstRow = max(0, Int((ra.minY / cellHeight).rounded(.down)))
        let lastRow = min(a.rows, Int((ra.maxY / cellHeight).rounded(.up)))
        guard lastColumn > firstColumn, lastRow > firstRow else { return nil }
        let shift = (rb.minY - ra.minY) / cellHeight
        let whole = Int(shift.rounded(.down)), part = shift - Double(whole)
        var sum = 0.0, count = 0
        for row in firstRow..<lastRow {
            let upper = row + whole, lower = part > 0 ? upper + 1 : upper
            guard upper >= 0, lower < b.rows else { return nil }
            for column in firstColumn..<lastColumn {
                let then = Double(a.cells[row * a.columns + column])
                let now = Double(b.cells[upper * b.columns + column]) * (1 - part) + Double(b.cells[lower * b.columns + column]) * part
                sum += abs(then - now)
                count += 1
            }
        }
        return sum / Double(count)
    }
}

extension ScreenSample {
    /// The grid of the strip `ScreenFollow` watches a frame of this size
    /// with: the whole frame, in rows of about 4 pixels (at most
    /// `ScrollRegion`'s 320) and columns of about 40.
    public static func stripGrid(width: Int, height: Int) -> (columns: Int, rows: Int) {
        guard width > 0, height > 0 else { return (1, 1) }
        let columns = min(ScrollRegion.maxCoarse, max(8, Int((Double(width) / ScrollRegion.coarseCell).rounded())))
        let rows = min(ScrollRegion.maxFine, max(1, Int((Double(height) / ScrollRegion.fineCell).rounded())))
        return (columns, rows)
    }
}
