import AvoProtocol
import Foundation
import Testing
@testable import AvoKeymap

/// Where a finger lands (`KeymapEngine(touchSpread:)`): a tap spreads across
/// its button's face, the eye's thumb within its box, and 0 spread touches
/// the exact points (the other suites run that way, deterministically).
@Suite struct TouchSpreadTests {
    private static let W = 2400.0, H = 1080.0

    private func engine(_ controls: [Control], fps: FPSSettings? = nil, spread: Double = 1) -> KeymapEngine {
        KeymapEngine(profile: KeymapProfile(package: "com.example.game", name: "Test", controls: controls, fps: fps),
                     displayID: 7, width: Self.W, height: Self.H, touchSpread: spread)
    }

    private func tapLandings(spread: Double = 1, size: Double? = nil, taps: Int = 30) -> [(x: Double, y: Double)] {
        var e = engine([Control(id: "jump", kind: .tap(NormalizedPoint(0.5, 0.5)), triggers: [.key(.space)], size: size)],
                       spread: spread)
        var landings: [(x: Double, y: Double)] = []
        for index in 0..<taps {
            let down = e.handle(.keyDown(.space), at: TimeInterval(index)).events
            landings += down.filter { $0.action == .down }.map { (Double($0.pointers[0].x), Double($0.pointers[0].y)) }
            _ = e.handle(.keyUp(.space), at: TimeInterval(index) + 0.01)
            _ = e.tick(at: TimeInterval(index) + 0.2)
        }
        return landings
    }

    @Test func tapsLandAcrossTheButtonNeverOnOnePixel() {
        let landings = tapLandings()
        #expect(landings.count == 30)
        // Inside the button's face: the spread is clipped at 80 % of its
        // radius, and the half-pixel is the rounding of Float coordinates.
        let reach = Control.defaultSize * Self.H / 2 * 0.8 + 0.51
        for (x, y) in landings {
            #expect(hypot(x - 1200, y - 540) <= reach)
        }
        let places = Set(landings.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" })
        #expect(places.count >= 24)
    }

    @Test func biggerButtonsSpreadFurther() {
        // A big button (a sixth of the display's height) takes taps well
        // apart; a small one keeps them close.
        let big = tapLandings(size: Control.sizeRange.upperBound, taps: 40)
        let distances = big.map { hypot($0.x - 1200, $0.y - 540) }
        #expect((distances.max() ?? 0) > 40)
        #expect(distances.allSatisfy { $0 <= Control.sizeRange.upperBound * Self.H / 2 * 0.8 + 0.51 })
    }

    @Test func eyeTouchdownsVaryWithinTheBox() {
        let camera = Control(id: "camera", kind: .aim(area: NormalizedRect(0.5, 0.1, 1, 0.7),
                                                      sensitivity: AxisPair(x: 1, y: 1), adsSensitivity: AxisPair(x: 1, y: 1),
                                                      exponent: 1, deadzone: 0, invertY: false, stick: nil))
        var e = engine([camera], fps: FPSSettings(aimControl: "camera"))
        var touchdowns: [(x: Double, y: Double)] = []
        for index in 0..<25 {
            let down = e.setPointerLocked(true)
            touchdowns += down.filter { $0.action == .down }.map { (Double($0.pointers[0].x), Double($0.pointers[0].y)) }
            _ = e.setPointerLocked(false)
            _ = e.tick(at: TimeInterval(index) + 0.1)
        }
        #expect(touchdowns.count == 25)
        // Somewhere in the box, clear of its edge.
        for (x, y) in touchdowns {
            #expect((1201...2399).contains(x))
            #expect((109...755).contains(y))
        }
        #expect(Set(touchdowns.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" }).count >= 20)
        // The thumb roams its box; it does not rest on one pixel.
        let furthest = touchdowns.map { hypot($0.x - 1800, $0.y - 432) }.max() ?? 0
        #expect(furthest > 40)
    }

    @Test func zeroSpreadTouchesTheExactPoint() {
        let landings = tapLandings(spread: 0, taps: 5)
        #expect(landings.allSatisfy { $0.x == 1200 && $0.y == 540 })
    }
}
