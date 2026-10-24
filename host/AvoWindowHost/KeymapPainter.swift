import AppKit
import AvoKeymap

/// Where key mapping controls sit and how they look, for the editor and for
/// the hints over the game. Positions are fractions of `displayRect` (where
/// the game is drawn, in the view's coordinates, y up) and radii fractions
/// of its height, so everything follows the window's size.
@MainActor
struct KeymapPainter {
    /// Objects to place and resize (editor), or key caps that label the
    /// game's own buttons while playing (hints).
    enum Style {
        case editor
        case hint
    }

    let displayRect: CGRect
    /// Editor: how solid the objects' fills are (Editor Opacity); outlines
    /// and keys stay readable, so a lower value shows the game through them.
    /// Hints: the player's Key Visibility; the keys stay readable
    /// at any value, only their plates fade.
    var opacity: CGFloat = 1
    /// Names under the objects (editor only).
    var captions = true
    /// Smart casts' drag rings (editor only): over the game the buttons are enough.
    var guides = true
    var style: Style = .editor
    /// Where the editor's own bar and inspector cover the game: an
    /// area's name and size stay out from under them.
    var obstacles: [CGRect] = []
    /// The layout's modes by id, for a Switch Mode action's badge.
    var modeNames: [String: String] = [:]

    static let handleRadius: CGFloat = 9
    static let minimumBubble: CGFloat = 14
    static let ink = NSColor(calibratedRed: 0.85, green: 0.91, blue: 0.65, alpha: 1)
    static let selection = NSColor.systemYellow

    static func isEye(_ control: Control) -> Bool {
        if case .aim = control.kind { return true }
        return false
    }

    /// The eye's point, where its finger touches down (its swipe area is drawn under it, by drawArea).
    static let eyeRadius: CGFloat = 24
    static let heroRadius: CGFloat = 16
    /// The corner and edge handles of a selected area: small squares, unlike
    /// the round × and ↘ handles of the controls.
    static let areaHandleSide: CGFloat = 9

    // MARK: Geometry (y up)

    func point(_ p: NormalizedPoint) -> CGPoint {
        CGPoint(x: displayRect.minX + p.x * displayRect.width, y: displayRect.maxY - p.y * displayRect.height)
    }

    func normalized(_ p: CGPoint) -> NormalizedPoint {
        guard displayRect.width > 0, displayRect.height > 0 else { return NormalizedPoint(0.5, 0.5) }
        return NormalizedPoint(min(max((p.x - displayRect.minX) / displayRect.width, 0), 1),
                               min(max((displayRect.maxY - p.y) / displayRect.height, 0), 1))
    }

    func anchor(of control: Control) -> NormalizedPoint {
        switch control.kind {
        case .tap(let p), .hold(let p), .ads(let p, _), .repeatTap(let p, _), .anchor(let p, _), .smartCast(let p, _, _): p
        case let .dpad(center, _, _, _, _, _, _), let .mobaMove(center, _): center
        case let .aim(area, _, _, _, _, _, _, origin): origin ?? area.center
        case .clickArea(let area, _): area.center
        // No place on the game.
        case .hotkey: NormalizedPoint(0.5, 0.5)
        case let .swipe(from, _, _): from
        case .macro(let steps):
            steps.lazy.compactMap { if case .tap(let p) = $0 { p } else if case .hold(let p, _) = $0 { p } else { nil } }.first
                ?? NormalizedPoint(0.5, 0.5)
        }
    }

    /// Every button the same size: its size never changed what it touches
    /// (a `size` from Avo before b64 is not drawn).
    func bubbleRadius(_ control: Control) -> CGFloat {
        max(CGFloat(Control.defaultSize) * displayRect.height, Self.minimumBubble)
    }

    /// How far an anchor tap's finger may go from its point, never inside
    /// the button itself; nil for the whole screen (and the other kinds).
    func anchorReach(_ control: Control) -> CGFloat? {
        guard case .anchor(_, let radius?) = control.kind else { return nil }
        return max(CGFloat(radius) * displayRect.height, bubbleRadius(control) + 6)
    }

    func dpadRadius(_ radius: Double) -> CGFloat {
        max(CGFloat(radius) * displayRect.height, 30)
    }

    /// How far a smart cast drags its button, never inside the button itself.
    func castRadius(_ control: Control) -> CGFloat {
        guard case let .smartCast(_, radius, _) = control.kind else { return bubbleRadius(control) }
        return max(CGFloat(radius) * displayRect.height, bubbleRadius(control) + 6)
    }

    func rect(of area: NormalizedRect) -> CGRect {
        let a = point(NormalizedPoint(area.minX, area.minY)), b = point(NormalizedPoint(area.maxX, area.maxY))
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    /// The box the × and ↘ handles sit on.
    func frame(of control: Control) -> CGRect {
        switch control.kind {
        case let .dpad(center, radius, _, _, _, _, _), let .mobaMove(center, radius):
            let c = point(center), r = dpadRadius(radius)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .smartCast:
            // The ↘ handle sets the cast radius, so the handles sit on its ring.
            let c = point(anchor(of: control)), r = castRadius(control)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .anchor:
            // On its reach's circle: the ↘ handle sets it.
            let c = point(anchor(of: control)), r = anchorReach(control) ?? bubbleRadius(control)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .aim:
            let c = point(anchor(of: control)), r = Self.eyeRadius
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        case .clickArea(let area, _):
            return rect(of: area)
        default:
            let c = point(anchor(of: control)), r = bubbleRadius(control)
            return CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        }
    }

    /// The × handle: the top right corner of the frame, kept on the display.
    func removeHandle(_ control: Control) -> CGPoint {
        let f = frame(of: control)
        return reachable(CGPoint(x: f.maxX, y: f.maxY))
    }

    /// The ↘ handle, kept on the display: a control near the edge (a smart
    /// cast's ring reaches past it) would otherwise have it out of reach.
    func resizeHandle(_ control: Control) -> CGPoint? {
        resizeCorner(control).map(reachable)
    }

    /// The bottom right corner of the frame, where the ↘ handle belongs. A
    /// resize drag measures from here, so a handle moved onto the display
    /// still changes the size smoothly instead of jumping.
    func resizeCorner(_ control: Control) -> CGPoint? {
        switch control.kind {
        case .dpad, .mobaMove, .smartCast, .anchor:
            let f = frame(of: control)
            return CGPoint(x: f.maxX, y: f.minY)
        default:
            // Only what reaches somewhere has a size: a button touches its point whatever its size.
            return nil
        }
    }

    /// `p` moved onto the display, a whole handle inside it.
    private func reachable(_ p: CGPoint) -> CGPoint {
        let inside = displayRect.insetBy(dx: Self.handleRadius, dy: Self.handleRadius)
        guard !inside.isNull, !inside.isEmpty else { return p }
        return CGPoint(x: min(max(p.x, inside.minX), inside.maxX), y: min(max(p.y, inside.minY), inside.maxY))
    }

    /// Where a D-pad shows its up, left, down and right keys.
    func dpadSlots(center c: CGPoint, radius r: CGFloat) -> [CGPoint] {
        [CGPoint(x: c.x, y: c.y + r * 0.66), CGPoint(x: c.x - r * 0.66, y: c.y),
         CGPoint(x: c.x, y: c.y - r * 0.66), CGPoint(x: c.x + r * 0.66, y: c.y)]
    }

    // MARK: Drawing

    /// One control. `activeSlot` highlights the D-pad direction the next key sets.
    func draw(_ control: Control, selected: Bool = false, activeSlot: Int? = nil, eyeKey: String? = nil) {
        if style == .hint { return drawHint(control, eyeKey: eyeKey) }
        let color = selected ? Self.selection : Self.ink
        switch control.kind {
        case .aim:
            // Just its point: the finger starts here and comes back here.
            let c = point(anchor(of: control)), r = Self.eyeRadius
            circle(at: c, radius: r, color: color, filled: true)
            let eye = CGPoint(x: c.x, y: c.y + 5), key = CGPoint(x: c.x, y: c.y - 9)
            let keys = eyeLabel(control, eyeKey: eyeKey)
            keyPlate(around: symbolRect("eye.fill", at: eye, size: 15).union(labelRect(keys, at: key, size: 10)), color: color)
            symbol("eye.fill", at: eye, size: 15, color: .black)
            label(keys, at: key, color: .black, size: 10)
            caption(eyeKey == nil && control.stick != nil ? String(localized: "Eye · stick look", bundle: .windowHost)
                                                          : String(localized: "Eye · mouse look", bundle: .windowHost),
                    below: frame(of: control), color: color)
        case let .dpad(center, radius, up, down, left, right, _):
            let c = point(center), r = dpadRadius(radius)
            // How far it goes while its run key is held: a dashed ring further out.
            if let run = control.run {
                let reach = r * CGFloat(run.scale)
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - reach, y: c.y - reach, width: 2 * reach, height: 2 * reach))
                ring.setLineDash([6, 4], count: 2, phase: 0)
                line(ring, color: fade(color, selected ? 0.9 : 0.5), width: 1.5)
            }
            fade(color, 0.12 * opacity).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            circle(at: c, radius: r, color: color, filled: false)
            let keys = [up, left, down, right]
            for (slot, at) in dpadSlots(center: c, radius: r).enumerated() {
                // The keys' discs stay solid: they are the D-pad's labels.
                let slotRadius = max(r * 0.2, 11)
                circle(at: at, radius: slotRadius, color: slot == activeSlot ? Self.selection : color, filled: true, solid: true)
                label(keys[slot].shortLabel, at: at, color: .black, size: min(max(slotRadius * 0.75, 9), 13))
            }
            circle(at: c, radius: max(r * 0.12, 5), color: color, filled: true, solid: true)
            // The controller's part that pushes it too: "D-pad · LS ✚".
            let pads = [control.stick.map { GamepadHub.shared.layout.label($0) }, control.dpadButtons ? "✚" : nil,
                        control.run.map { String(localized: "\($0.trigger.shortLabel) runs", bundle: .windowHost) }].compactMap { $0 }
            caption(([String(localized: "D-pad", bundle: .windowHost)] + pads).joined(separator: " · "), below: frame(of: control), color: color)
        case let .swipe(from, to, _):
            let a = point(from), b = point(to)
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            line(path, color: fade(color), width: 3)
            arrowHead(at: b, from: a, color: color)
            circle(at: b, radius: 6, color: color, filled: true, solid: true)
            bubble(control, at: a, color: color, symbolName: nil)
            caption(String(localized: "Swipe", bundle: .windowHost), below: frame(of: control), color: color)
        case .anchor:
            let c = point(anchor(of: control))
            // Its reach: a faint disc in a dashed ring, like a joystick's.
            if let r = anchorReach(control) {
                fade(color, (selected ? 0.12 : 0.07) * opacity).setFill()
                NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ring.setLineDash([6, 4], count: 2, phase: 0)
                line(ring, color: fade(color, selected ? 0.95 : 0.6), width: 1.5)
            }
            bubble(control, at: c, color: color, symbolName: "arrow.up.and.down.and.arrow.left.and.right")
            let r = bubbleRadius(control)
            caption(String(localized: "Anchor tap", bundle: .windowHost), below: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                    color: color)
        case .hotkey, .clickArea:
            // A hotkey has no place on the game; a click area is drawn under the controls (drawClickArea).
            break
        case .repeatTap:
            bubble(control, at: point(anchor(of: control)), color: color, symbolName: "repeat")
            caption(String(localized: "Repeat", bundle: .windowHost), below: frame(of: control), color: color)
        case .ads:
            bubble(control, at: point(anchor(of: control)), color: color, symbolName: "scope")
            caption(String(localized: "Aim down sights", bundle: .windowHost), below: frame(of: control), color: color)
        case .macro:
            bubble(control, at: point(anchor(of: control)), color: color, symbolName: nil)
            caption(String(localized: "Macro", bundle: .windowHost), below: frame(of: control), color: color)
        case let .mobaMove(center, radius):
            // A joystick ring with its knob: the knob carries the trigger.
            let c = point(center), r = dpadRadius(radius)
            fade(color, 0.12 * opacity).setFill()
            NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill()
            circle(at: c, radius: r, color: color, filled: false)
            let knob = max(r * 0.34, Self.minimumBubble)
            circle(at: c, radius: knob, color: color, filled: true)
            let size = min(max(knob * 0.5, 9), 15)
            let mark = CGPoint(x: c.x, y: c.y + knob * 0.3), key = CGPoint(x: c.x, y: c.y - knob * 0.32)
            keyPlate(around: symbolRect("cursorarrow.motionlines", at: mark, size: size)
                .union(labelRect(triggerText(control), at: key, size: size * 0.85)), color: color)
            symbol("cursorarrow.motionlines", at: mark, size: size, color: .black)
            label(triggerText(control), at: key, color: .black, size: size * 0.85)
            caption(String(localized: "Move by mouse", bundle: .windowHost), below: frame(of: control), color: color)
        case .smartCast:
            let c = point(anchor(of: control))
            if guides {
                let r = castRadius(control)
                let ring = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                ring.setLineDash([5, 4], count: 2, phase: 0)
                line(ring, color: fade(color, selected ? 0.9 : 0.5), width: 1.5)
            }
            bubble(control, at: c, color: color, symbolName: "sparkles")
            // Under the button: the rings of neighbouring skills overlap.
            let r = bubbleRadius(control)
            caption(String(localized: "Smart cast", bundle: .windowHost), below: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r),
                    color: color)
        case .tap, .hold:
            bubble(control, at: point(anchor(of: control)), color: color, symbolName: nil)
        }
    }

    /// Where MOBA controls aim from (editor): a marker on the hero.
    func drawHero(at p: NormalizedPoint, selected: Bool) {
        let color = selected ? Self.selection : Self.ink
        let c = point(p), r = Self.heroRadius
        circle(at: c, radius: r, color: color, filled: true)
        keyPlate(around: symbolRect("figure.stand", at: c, size: 15), color: color)
        symbol("figure.stand", at: c, size: 15, color: .black)
        let ticks = NSBezierPath()
        for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
            ticks.move(to: CGPoint(x: c.x + dx * (r + 3), y: c.y + dy * (r + 3)))
            ticks.line(to: CGPoint(x: c.x + dx * (r + 10), y: c.y + dy * (r + 10)))
        }
        line(ticks, color: fade(color), width: 2)
        caption(String(localized: "Hero", bundle: .windowHost), below: CGRect(x: c.x - r, y: c.y - r - 8, width: 2 * r, height: 2 * r),
                color: color)
    }

    /// The × and ↘ handles of one control (editor).
    func drawHandles(_ control: Control, emphasized: Bool, hotRemove: Bool, hotResize: Bool) {
        let alpha: CGFloat = emphasized ? 1 : 0.7
        let remove = removeHandle(control)
        handle(at: remove, alpha: alpha, hot: hotRemove)
        cross(at: remove, alpha: alpha)
        if let resize = resizeHandle(control) {
            handle(at: resize, alpha: alpha, hot: hotResize)
            symbol("arrow.up.left.and.arrow.down.right", at: resize, size: 9, color: NSColor.white.withAlphaComponent(alpha))
        }
    }

    // MARK: Areas (editor)

    /// Where an eye's swipe area or a click area lies; nil for the other kinds.
    func areaRect(of control: Control) -> CGRect? { control.area.map(rect(of:)) }

    /// The corner and edge handles of an area, kept on the display, each
    /// with the edges it moves (`top` is the one nearer the top of the screen).
    func areaHandles(_ r: CGRect) -> [(edges: NormalizedRect.Edges, at: CGPoint)] {
        let handles: [(NormalizedRect.Edges, CGPoint)] = [
            ([.top, .left], CGPoint(x: r.minX, y: r.maxY)), (.top, CGPoint(x: r.midX, y: r.maxY)),
            ([.top, .right], CGPoint(x: r.maxX, y: r.maxY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
            ([.bottom, .right], CGPoint(x: r.maxX, y: r.minY)), (.bottom, CGPoint(x: r.midX, y: r.minY)),
            ([.bottom, .left], CGPoint(x: r.minX, y: r.minY)), (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
        return handles.map { (edges: $0.0, at: reachable($0.1)) }
    }

    /// An eye's swipe area, under the controls: a faint fill in a dashed
    /// frame, solid and named while it is selected (and named under the pointer).
    func drawArea(_ control: Control, selected: Bool, hovered: Bool) {
        guard let r = areaRect(of: control) else { return }
        let color = selected ? Self.selection : Self.ink
        fade(color, (selected ? 0.18 : hovered ? 0.14 : 0.1) * opacity).setFill()
        NSBezierPath(rect: r).fill()
        let frame = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
        if !selected { frame.setLineDash([7, 5], count: 2, phase: 0) }
        line(frame, color: fade(color, selected ? 1 : hovered ? 0.8 : 0.55), width: selected ? 2 : 1.5)
        guard selected || hovered else { return }
        tag(String(localized: "Swipe area", bundle: .windowHost), inside: r, color: color)
    }

    /// A click area, under the controls: a tinted rectangle in a dotted
    /// frame with a click mark in its middle, named in its corner, and what
    /// it does under it (its actions' badges).
    func drawClickArea(_ control: Control, selected: Bool, hovered: Bool) {
        guard case let .clickArea(area, passThrough) = control.kind else { return }
        let r = rect(of: area)
        let color = selected ? Self.selection : Self.ink
        fade(color, (selected ? 0.2 : hovered ? 0.16 : 0.11) * opacity).setFill()
        NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
        let frame = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4)
        frame.setLineDash(selected ? [] : [2, 3], count: selected ? 0 : 2, phase: 0)
        line(frame, color: fade(color, selected ? 1 : hovered ? 0.85 : 0.65), width: selected ? 2 : 1.5)
        let c = CGPoint(x: r.midX, y: r.midY)
        let size = min(max(min(r.width, r.height) * 0.3, 10), 20)
        keyPlate(around: symbolRect("cursorarrow.click.2", at: c, size: size), color: color)
        symbol("cursorarrow.click.2", at: c, size: size, color: fade(color, passThrough ? 1 : 0.6))
        tag(String(localized: "Click area", bundle: .windowHost), inside: r, color: color)
    }

    /// What a control does besides its touch, on the game (editor): a row
    /// of small badges beside its button, a switch's with its mode's name.
    func drawActionBadges(_ control: Control) {
        guard style == .editor, !control.actions.isEmpty else { return }
        let start: CGPoint
        switch control.kind {
        case .clickArea(let area, _):
            let r = rect(of: area)
            start = CGPoint(x: r.minX + 9, y: r.minY - 11)
        case let .mobaMove(center, radius):
            let c = point(center), r = dpadRadius(radius)
            start = CGPoint(x: c.x + r * 0.34 + 12, y: c.y)
        case let .swipe(from, _, _):
            let c = point(from)
            start = CGPoint(x: c.x + bubbleRadius(control) + 11, y: c.y)
        default:
            let c = point(anchor(of: control))
            start = CGPoint(x: c.x + bubbleRadius(control) + 11, y: c.y)
        }
        var x = start.x
        for action in control.actions {
            let name: String? = if case .switchMode(let mode) = action { modeNames[mode] ?? mode } else { nil }
            let symbolName = action.symbol
            let text = name.map { String($0.prefix(14)) }
            let textWidth = text.map { labelRect($0, at: .zero, size: 9.5).width } ?? 0
            let width: CGFloat = text == nil ? 16 : 16 + textWidth + 6
            let plate = CGRect(x: x - 8, y: start.y - 8, width: width, height: 16)
            Self.ink.setFill()
            NSBezierPath(roundedRect: plate, xRadius: 8, yRadius: 8).fill()
            NSColor.black.withAlphaComponent(0.45).setStroke()
            let edge = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: 7.5, yRadius: 7.5)
            edge.lineWidth = 1
            edge.stroke()
            symbol(symbolName, at: CGPoint(x: x, y: start.y), size: 8.5, color: .black)
            if let text { label(text, at: CGPoint(x: x + 8 + textWidth / 2 + 1, y: start.y), color: .black, size: 9.5) }
            x += width + 3
        }
    }

    /// The selected area's corner and edge handles; `hot` is the one under the pointer.
    func drawAreaHandles(_ control: Control, hot: NormalizedRect.Edges?) {
        guard let r = areaRect(of: control) else { return }
        let s = Self.areaHandleSide
        for (edges, at) in areaHandles(r) {
            let square = NSBezierPath(roundedRect: CGRect(x: at.x - s / 2, y: at.y - s / 2, width: s, height: s), xRadius: 2, yRadius: 2)
            (edges == hot ? Self.selection : NSColor.white).setFill()
            square.fill()
            square.lineWidth = 1
            NSColor.black.withAlphaComponent(0.7).setStroke()
            square.stroke()
        }
    }

    /// An area's size while it is dragged, beside the pointer: its width and
    /// height in percent of the screen.
    func drawAreaSize(_ control: Control, near pointer: CGPoint) {
        guard let area = control.area else { return }
        let text = Self.sizeText(area)
        let measured = labelRect(text, at: .zero, size: 12)
        let size = CGSize(width: measured.width + 16, height: measured.height + 6)
        // Below and right of the pointer, else at another of its corners:
        // on the display and clear of the bar and the inspector.
        let corners = [CGPoint(x: pointer.x + 14, y: pointer.y - 14 - size.height), CGPoint(x: pointer.x - 14 - size.width, y: pointer.y - 14 - size.height),
                       CGPoint(x: pointer.x + 14, y: pointer.y + 14), CGPoint(x: pointer.x - 14 - size.width, y: pointer.y + 14)]
        let inside = displayRect.insetBy(dx: 4, dy: 4)
        let fits = corners.map { CGRect(origin: $0, size: size) }.first { inside.contains($0) && !obstacles.contains(where: $0.intersects) }
        var plate = fits ?? CGRect(origin: corners[0], size: size)
        plate.origin.x = max(min(plate.minX, displayRect.maxX - 4 - plate.width), displayRect.minX + 4)
        plate.origin.y = max(min(plate.minY, displayRect.maxY - 4 - plate.height), displayRect.minY + 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        label(text, at: CGPoint(x: plate.midX, y: plate.midY), color: .white, size: 12)
    }

    /// "52% × 90% of the screen": an area's width and height.
    static func sizeText(_ area: NormalizedRect) -> String {
        let width = Int((area.width * 100).rounded()), height = Int((area.height * 100).rounded())
        return String(localized: "\(width)% × \(height)% of the screen", bundle: .windowHost)
    }

    /// A name in the top left corner of an area, on a dark plate.
    private func tag(_ text: String, inside r: CGRect, color: NSColor) {
        guard captions else { return }
        let measured = labelRect(text, at: .zero, size: 10)
        var plate = CGRect(x: r.minX + 6, y: r.maxY - 6 - (measured.height + 2), width: measured.width + 10, height: measured.height + 2)
        plate.origin.x = max(min(plate.minX, displayRect.maxX - 4 - plate.width), displayRect.minX + 4)
        plate.origin.y = max(min(plate.minY, displayRect.maxY - 4 - plate.height), displayRect.minY + 4)
        // Down the area's left edge, out from under the bar.
        for obstacle in obstacles where obstacle.intersects(plate) && obstacle.minY - 4 - plate.height > r.minY {
            plate.origin.y = obstacle.minY - 4 - plate.height
        }
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        label(text, at: CGPoint(x: plate.midX, y: plate.midY), color: color, size: 10)
    }

    private func fade(_ color: NSColor, _ alpha: CGFloat = 1) -> NSColor {
        color.withAlphaComponent(color.alphaComponent * alpha)
    }

    private func bubble(_ control: Control, at c: CGPoint, color: NSColor, symbolName: String?) {
        let r = bubbleRadius(control)
        circle(at: c, radius: r, color: color, filled: true)
        let text = triggerText(control)
        let size = min(max(r * 0.55, 10), 18)
        if let symbolName {
            let mark = CGPoint(x: c.x, y: c.y + r * 0.28), key = CGPoint(x: c.x, y: c.y - r * 0.3)
            keyPlate(around: symbolRect(symbolName, at: mark, size: size * 0.9).union(labelRect(text, at: key, size: size * 0.85)), color: color)
            symbol(symbolName, at: mark, size: size * 0.9, color: .black)
            label(text, at: key, color: .black, size: size * 0.85)
        } else {
            keyPlate(around: labelRect(text, at: c, size: size), color: color)
            label(text, at: c, color: .black, size: size)
        }
    }

    /// Behind the key of a see-through object (Editor Opacity below 100%): a
    /// plate of the object's colour, so the key reads as on a solid object.
    /// With the fill under it, it covers exactly as much as a solid fill,
    /// so nothing changes at 100%.
    private func keyPlate(around content: CGRect, color: NSColor) {
        let fill = 0.9 * opacity
        guard fill < 0.89 else { return }
        let alpha = 1 - 0.1 / (1 - fill)
        let plate = content.insetBy(dx: -4, dy: -2)
        let radius = min(plate.height / 2, 8)
        fade(color, alpha).setFill()
        NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius).fill()
    }

    private func triggerText(_ control: Control) -> String {
        control.triggers.isEmpty ? "?" : control.triggers.map { $0.shortLabel }.joined(separator: " ")
    }

    /// The eye's keys: the key that locks the mouse for it and its stick ("F8 RS"), "?" with neither.
    private func eyeLabel(_ control: Control, eyeKey: String?) -> String {
        let parts = [eyeKey, control.stick.map { GamepadHub.shared.layout.label($0) }].compactMap { $0 }
        return parts.isEmpty ? "?" : parts.joined(separator: " ")
    }

    /// A part of the controller dragged from the controller panel, under
    /// the pointer (editor): its glyph, ringed in the selection colour where
    /// letting go binds it to a control, and what letting go does.
    func drawGhost(symbol name: String, caption text: String, at c: CGPoint, binding: Bool) {
        let r: CGFloat = 22
        let color = binding ? Self.selection : Self.ink
        circle(at: c, radius: r, color: color, filled: true, solid: true)
        symbol(name, at: c, size: 22, color: .black)
        caption(text, below: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r), color: color)
    }

    /// Where a click on the game put a tap that waits for its key (editor):
    /// a dashed ring in the selection colour, "?", and "Press a key" under it.
    func drawPendingTap(at c: CGPoint) {
        let r = max(CGFloat(Control.defaultSize) * displayRect.height, Self.minimumBubble)
        let box = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
        Self.selection.withAlphaComponent(0.22).setFill()
        NSBezierPath(ovalIn: box).fill()
        let ring = NSBezierPath(ovalIn: box)
        ring.setLineDash([4, 3], count: 2, phase: 0)
        line(ring, color: Self.selection, width: 2)
        label("?", at: c, color: Self.selection, size: min(max(r * 0.7, 11), 18))
        caption(String(localized: "Press a key", bundle: .windowHost), below: box, color: Self.selection)
    }

    /// A control that acts in every mode of a layout with modes (editor): a
    /// small ∞ on the top left of its frame.
    func drawEveryModeBadge(_ control: Control) {
        let f = frame(of: control)
        let c = reachable(CGPoint(x: f.minX, y: f.maxY))
        circle(at: c, radius: 8, color: Self.ink, filled: true, solid: true)
        symbol("infinity", at: c, size: 8.5, color: .black)
    }

    private func handle(at c: CGPoint, alpha: CGFloat, hot: Bool) {
        let r = Self.handleRadius
        let path = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        (hot ? NSColor.systemRed : NSColor(calibratedWhite: 0.12, alpha: 1)).withAlphaComponent(alpha).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(alpha * 0.8).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func cross(at c: CGPoint, alpha: CGFloat) {
        let d: CGFloat = 3.5
        let path = NSBezierPath()
        path.move(to: CGPoint(x: c.x - d, y: c.y - d))
        path.line(to: CGPoint(x: c.x + d, y: c.y + d))
        path.move(to: CGPoint(x: c.x - d, y: c.y + d))
        path.line(to: CGPoint(x: c.x + d, y: c.y - d))
        path.lineWidth = 1.6
        NSColor.white.withAlphaComponent(alpha).setStroke()
        path.stroke()
    }

    private func arrowHead(at tip: CGPoint, from start: CGPoint, color: NSColor) {
        let angle = atan2(tip.y - start.y, tip.x - start.x)
        let length: CGFloat = 12
        let path = NSBezierPath()
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - length * cos(angle - .pi / 7), y: tip.y - length * sin(angle - .pi / 7)))
        path.move(to: tip)
        path.line(to: CGPoint(x: tip.x - length * cos(angle + .pi / 7), y: tip.y - length * sin(angle + .pi / 7)))
        line(path, color: fade(color), width: 3)
    }

    /// A ring, filled as solid as the editor's opacity allows (`solid`: the
    /// small discs that carry a key, which stay readable).
    private func circle(at center: CGPoint, radius: CGFloat, color: NSColor, filled: Bool, solid: Bool = false) {
        let path = NSBezierPath(ovalIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        if filled {
            fade(color, 0.9 * (solid ? 1 : opacity)).setFill()
            path.fill()
        }
        line(path, color: fade(color), width: 2)
    }

    /// A line with a thin dark edge on both sides, so a lime or yellow line
    /// still shows over a white sky.
    private func line(_ path: NSBezierPath, color: NSColor, width: CGFloat) {
        path.lineWidth = width + 2
        NSColor.black.withAlphaComponent(0.35 * color.alphaComponent).setStroke()
        path.stroke()
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private func label(_ text: String, at center: CGPoint, color: NSColor, size: CGFloat = 11) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                         .foregroundColor: fade(color)]
        let measured = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(at: CGPoint(x: center.x - measured.width / 2, y: center.y - measured.height / 2), withAttributes: attributes)
    }

    /// Where `label` draws `text`.
    private func labelRect(_ text: String, at center: CGPoint, size: CGFloat) -> CGRect {
        let measured = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: .semibold)])
        return CGRect(x: center.x - measured.width / 2, y: center.y - measured.height / 2, width: measured.width, height: measured.height)
    }

    /// The name under an object, on a dark plate: the editor shows the game
    /// through itself, and lime text alone is lost on a bright scene.
    private func caption(_ text: String, below frame: CGRect, color: NSColor) {
        guard captions else { return }
        let at = CGPoint(x: frame.midX, y: frame.minY - 10)
        let plate = labelRect(text, at: at, size: 10).insetBy(dx: -5, dy: -1)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: plate, xRadius: plate.height / 2, yRadius: plate.height / 2).fill()
        label(text, at: at, color: color, size: 10)
    }

    private func symbolImage(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold).applying(.init(paletteColors: [color])))
    }

    private func symbol(_ name: String, at center: CGPoint, size: CGFloat, color: NSColor) {
        guard let image = symbolImage(name, size: size, color: fade(color)) else { return }
        let s = image.size
        image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
    }

    /// Where `symbol` draws `name`.
    private func symbolRect(_ name: String, at center: CGPoint, size: CGFloat) -> CGRect {
        let s = symbolImage(name, size: size, color: .black)?.size ?? CGSize(width: size, height: size)
        return CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height)
    }

    // MARK: Hints over the game

    /// How much of the game a key cap's plate covers, and how solid its
    /// outline and text are, at the player's Key Visibility. The
    /// text never fades far: it is the point of the hint.
    private var capPlate: CGFloat { 0.3 + 0.5 * opacity }
    private var capOutline: CGFloat { 0.3 + 0.45 * opacity }
    private var capText: CGFloat { 0.85 + 0.15 * opacity }

    /// The keys' text size: it follows the window (the display's height) and
    /// the control's size, within limits that keep it readable in a small
    /// window and unobtrusive in full screen.
    private func capFontSize(radius: CGFloat) -> CGFloat {
        min(max(radius * 0.75, capFontRange.low), capFontRange.high)
    }

    private var capFontRange: (low: CGFloat, high: CGFloat) {
        let h = displayRect.height
        return (min(max(h * 0.021, 11), 14), min(max(h * 0.032, 14), 22))
    }

    private static func capFont(_ size: CGFloat) -> NSFont {
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let rounded = font.fontDescriptor.withDesign(.rounded) else { return font }
        return NSFont(descriptor: rounded, size: size) ?? font
    }

    /// One control as key caps on the game: no fills over the game's
    /// buttons, and no captions or drag guides.
    private func drawHint(_ control: Control, eyeKey: String?) {
        let c = point(anchor(of: control))
        switch control.kind {
        case .aim:
            // As big as a button's: the eye is a point, not a button.
            keyCap(eyeLabel(control, eyeKey: eyeKey), symbol: "eye.fill", at: c,
                   size: capFontSize(radius: CGFloat(Control.defaultSize) * displayRect.height))
        case let .dpad(center, radius, up, down, left, right, _):
            let c = point(center), r = dpadRadius(radius)
            stickRing(center: c, radius: r)
            dot(at: c, radius: max(r * 0.06, 2.5))
            let size = capFontSize(radius: r * 0.3)
            for (slot, at) in dpadSlots(center: c, radius: r).enumerated() {
                keyCap([up, left, down, right][slot].shortLabel, at: at, size: size)
            }
            // The key held to run, under the joystick.
            if let run = control.run {
                keyCap(run.trigger.shortLabel, symbol: "figure.run", at: CGPoint(x: c.x, y: c.y - r - size * 1.4), size: size)
            }
        case let .mobaMove(center, radius):
            let c = point(center), r = dpadRadius(radius)
            stickRing(center: c, radius: r)
            keyCap(triggerText(control), symbol: "cursorarrow.motionlines", at: c, size: capFontSize(radius: r * 0.34))
        case let .swipe(from, to, _):
            let a = point(from), b = point(to)
            let path = NSBezierPath()
            path.move(to: a)
            path.line(to: b)
            path.lineCapStyle = .round
            twoToneStroke(path, width: 2)
            let head = NSBezierPath()
            let angle = atan2(b.y - a.y, b.x - a.x), length: CGFloat = 10
            head.move(to: CGPoint(x: b.x - length * cos(angle - .pi / 7), y: b.y - length * sin(angle - .pi / 7)))
            head.line(to: b)
            head.line(to: CGPoint(x: b.x - length * cos(angle + .pi / 7), y: b.y - length * sin(angle + .pi / 7)))
            head.lineCapStyle = .round
            head.lineJoinStyle = .round
            twoToneStroke(head, width: 2)
            keyCap(triggerText(control), at: a, size: capFontSize(radius: bubbleRadius(control)))
        case .anchor:
            keyCap(triggerText(control), symbol: "arrow.up.and.down.and.arrow.left.and.right", at: c, size: capFontSize(radius: bubbleRadius(control)))
        case .repeatTap:
            keyCap(triggerText(control), symbol: "repeat", at: c, size: capFontSize(radius: bubbleRadius(control)))
        case .ads:
            keyCap(triggerText(control), symbol: "scope", at: c, size: capFontSize(radius: bubbleRadius(control)))
        case .smartCast:
            keyCap(triggerText(control), symbol: "sparkles", at: c, size: capFontSize(radius: bubbleRadius(control)))
        case .macro, .tap, .hold:
            keyCap(triggerText(control), at: c, size: capFontSize(radius: bubbleRadius(control)))
        case .hotkey, .clickArea:
            // They touch nothing on the game: no cap over it.
            break
        }
    }

    /// A key cap: the key in bold AvoFlesh (`ink`: Avo's colour, unlike the
    /// game's own mostly white buttons) on a dark translucent plate with
    /// a thin light outline, a circle for one character and a pill for
    /// more. The letters have a dark outline of their own, so they read on
    /// a white sky even where the plate is faint, and the light outline
    /// keeps the cap's edge on dark scenes. Flat, without a bezel, so it
    /// reads as a label on the game's button rather than a button of its own.
    private func keyCap(_ text: String, symbol name: String? = nil, at center: CGPoint, size: CGFloat) {
        // Long labels (Space, R-Click) a little smaller, so the cap stays near the button's size.
        let fontSize = (text.count > 2 ? max(size * 0.84, capFontRange.low * 0.92) : size).rounded()
        // A lone mark (the eye's ` key) is tiny at that size: larger, centred on its own ink.
        let mark = text.count == 1 && "`'.,;:-=/\\[]".contains(text)
        let font = Self.capFont(mark ? (fontSize * 1.4).rounded() : fontSize)
        let ink = Self.ink.withAlphaComponent(capText)
        let halo = NSColor.black.withAlphaComponent(0.55 + 0.35 * opacity)
        let fill: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ink]
        // Stroke only (a positive width, in percent of the font size): half
        // of it lies outside the letters, the fill covers the rest.
        let stroke: [NSAttributedString.Key: Any] = [.font: font, .strokeColor: halo, .strokeWidth: 22]
        let textWidth = ceil((text as NSString).size(withAttributes: fill).width)
        let symbolSize = (fontSize * 0.82).rounded()
        let image = name.flatMap { symbolImage($0, size: symbolSize, color: ink) }
        let gap = (fontSize * 0.25).rounded()
        let contentWidth = textWidth + (image.map { ceil($0.size.width) + gap } ?? 0)
        let height = (fontSize * 1.55).rounded()
        let padding = text.count == 1 && image == nil ? fontSize * 0.5 : fontSize * 0.9
        let width = max(height, (contentWidth + padding).rounded())
        // Whole points, so the text stays sharp on 1× displays.
        let plate = CGRect(x: (center.x - width / 2).rounded(), y: (center.y - height / 2).rounded(), width: width, height: height)
        let path = NSBezierPath(roundedRect: plate, xRadius: height / 2, yRadius: height / 2)
        NSColor(calibratedWhite: 0.04, alpha: capPlate).setFill()
        path.fill()
        let outline = NSBezierPath(roundedRect: plate.insetBy(dx: 0.5, dy: 0.5), xRadius: height / 2 - 0.5, yRadius: height / 2 - 0.5)
        outline.lineWidth = 1
        NSColor.white.withAlphaComponent(Self.increaseContrast ? 1 : capOutline).setStroke()
        outline.stroke()
        var x = (plate.midX - contentWidth / 2).rounded()
        if let image, let dark = name.flatMap({ symbolImage($0, size: symbolSize, color: halo) }) {
            let s = image.size
            let rect = CGRect(x: x, y: (plate.midY - s.height / 2).rounded(), width: s.width, height: s.height)
            for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0)] { dark.draw(in: rect.offsetBy(dx: dx, dy: dy)) }
            image.draw(in: rect)
            x += ceil(s.width) + gap
        }
        // Centred on the capitals' height, which is what a key's legend lines up on.
        var baseline = plate.midY - font.capHeight / 2
        if mark {
            let glyph = (text as NSString).boundingRect(with: CGSize(width: 1000, height: 1000), options: .usesDeviceMetrics, attributes: fill)
            baseline = plate.midY - glyph.midY
        }
        let origin = CGPoint(x: x, y: (baseline + font.descender).rounded())
        (text as NSString).draw(at: origin, withAttributes: stroke)
        (text as NSString).draw(at: origin, withAttributes: fill)
    }

    /// A stick's travel: a faint disc in a ring that reads on any scene
    /// (a dark line under a light one).
    private func stickRing(center c: CGPoint, radius r: CGFloat) {
        let disc = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        NSColor.black.withAlphaComponent(capPlate * 0.25).setFill()
        disc.fill()
        twoToneStroke(disc, width: 1.5)
    }

    private func twoToneStroke(_ path: NSBezierPath, width: CGFloat) {
        path.lineWidth = width + 2.5
        NSColor.black.withAlphaComponent(0.2 + 0.4 * opacity).setStroke()
        path.stroke()
        path.lineWidth = width
        Self.ink.withAlphaComponent(Self.increaseContrast ? 1 : 0.45 + 0.45 * opacity).setStroke()
        path.stroke()
    }

    private func dot(at c: CGPoint, radius r: CGFloat) {
        let path = NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        Self.ink.withAlphaComponent(capText).setFill()
        path.fill()
        path.lineWidth = 1
        NSColor.black.withAlphaComponent(0.5).setStroke()
        path.stroke()
    }

    /// Increase Contrast: solid outlines on the key caps and rings.
    private static var increaseContrast: Bool { NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast }
}

/// "Show on game" and how opaque it is, remembered per app (the shim's defaults).
@MainActor
enum KeymapHints {
    static let changed = Notification.Name("com.avodroid.KeymapHintsChanged")
    static let opacityRange = 0.15...1.0
    /// Clear but light: the keys read on any scene, their plates let the
    /// game's buttons show through.
    static let defaultOpacity = 0.75

    static var visible: Bool {
        get { UserDefaults.standard.object(forKey: "AvoKeymapHintsVisible") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "AvoKeymapHintsVisible")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    static var opacity: Double {
        get { UserDefaults.standard.object(forKey: "AvoKeymapHintsOpacity") as? Double ?? defaultOpacity }
        set {
            UserDefaults.standard.set(min(max(newValue, opacityRange.lowerBound), opacityRange.upperBound), forKey: "AvoKeymapHintsOpacity")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// Key Visibility's steps (menus); the editor's slider moves in 5% steps.
    static var steps: [(opacity: Double, title: String)] {
        let low = 25, medium = 50, high = 75, full = 100
        return [(0.25, String(localized: "Low (\(low)%)", bundle: .windowHost)),
                (0.5, String(localized: "Medium (\(medium)%)", bundle: .windowHost)),
                (0.75, String(localized: "High (\(high)%)", bundle: .windowHost)),
                (1, String(localized: "Full (\(full)%)", bundle: .windowHost))]
    }
}

/// Key Visibility, under Show Keys on Game in the title bar's game
/// controller menu and in Game Controls: steps of KeymapHints.opacity
/// (the editor has a slider), and the value in use when it is none of
/// them ("Custom (18%)"). Choosing one also shows the key mapping.
@MainActor
final class KeymapHintsMenu: NSObject, NSMenuItemValidation, NSMenuDelegate {
    static let shared = KeymapHintsMenu()
    private static let custom = NSUserInterfaceItemIdentifier("avo.keymapHints.custom")

    /// A new item with the submenu (each menu needs its own).
    func makeItem() -> NSMenuItem {
        let submenu = NSMenu(title: String(localized: "Key Visibility", bundle: .windowHost))
        submenu.delegate = self
        for step in KeymapHints.steps {
            let item = submenu.addItem(withTitle: step.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = step.opacity
        }
        let custom = submenu.addItem(withTitle: "", action: #selector(choose(_:)), keyEquivalent: "")
        custom.target = self
        custom.identifier = Self.custom
        menuNeedsUpdate(submenu)
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        item.symbol("circle.lefthalf.filled")
        return item
    }

    /// Shows the value in use, in its place among the steps, when it is not one of them.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let custom = menu.items.first(where: { $0.identifier == Self.custom }) else { return }
        let opacity = KeymapHints.opacity
        custom.isHidden = KeymapHints.steps.contains { abs($0.opacity - opacity) < 0.01 }
        custom.title = String(localized: "Custom (\(Int((opacity * 100).rounded()))%)", bundle: .windowHost)
        custom.representedObject = opacity
        let index = KeymapHints.steps.filter { $0.opacity < opacity }.count
        if menu.index(of: custom) != index {
            menu.removeItem(custom)
            menu.insertItem(custom, at: index)
        }
    }

    @objc private func choose(_ item: NSMenuItem) {
        guard let opacity = item.representedObject as? Double else { return }
        KeymapHints.opacity = opacity
        if !KeymapHints.visible { KeymapHints.visible = true }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(choose(_:)), let opacity = item.representedObject as? Double {
            item.state = KeymapHints.visible && abs(KeymapHints.opacity - opacity) < 0.01 ? .on : .off
        }
        return true
    }
}

/// The key mapping drawn over the game while playing ("Show on game"): key
/// caps on the game's buttons, at the visibility the player chose. It never
/// takes a click.
@MainActor
final class KeymapHintsView: NSView {
    var profile: KeymapProfile? { didSet { needsDisplay = true } }
    /// The layout's mode now (KeymapController): only its controls show.
    var mode: String? { didSet { if mode != oldValue { needsDisplay = true } } }
    /// Hidden while the editor is open (it shows everything itself) and
    /// outside Game Mode (the mapping is not in charge then).
    var editing = false { didSet { update() } }
    var gameMode = false { didSet { update() } }
    private let displayRect: () -> CGRect
    private var observer: (any NSObjectProtocol)?

    init(displayRect: @escaping () -> CGRect) {
        self.displayRect = displayRect
        super.init(frame: .zero)
        wantsLayer = true
        observer = NotificationCenter.default.addObserver(forName: KeymapHints.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var isOpaque: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    private func update() {
        isHidden = editing || !gameMode || !KeymapHints.visible
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let profile else { return }
        let painter = KeymapPainter(displayRect: displayRect(), opacity: CGFloat(KeymapHints.opacity), captions: false, guides: false,
                                    style: .hint)
        let eyeKey = profile.fps?.cursorToggle.shortLabel
        let shown = profile.controls.filter { $0.belongs(to: mode) && $0.touchesTheScreen }
        for control in shown where KeymapPainter.isEye(control) { painter.draw(control, eyeKey: eyeKey) }
        for control in shown where !KeymapPainter.isEye(control) { painter.draw(control) }
    }
}
