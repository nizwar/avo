import AvoProtocol
import Foundation

/// Turns keyboard, mouse and gamepad input into multitouch events for one
/// display, following a `KeymapProfile`.
///
/// The engine is a pure state machine: the Window Host feeds it input with
/// timestamps, calls `tick(at:)` on every display refresh, and sends the
/// resulting `TouchEvent`s over the Input channel. Every event carries the full
/// pointer set, as Android's MotionEvent expects.
public struct KeymapEngine: Sendable {
    public static let tapDurationMilliseconds = 40
    /// Mouse counts per second at full gamepad stick deflection (at the
    /// stick's standard sensitivity; StickSettings).
    public static let stickAimSpeed = 1400.0
    /// How long a stick that drives the eye rests before its finger lifts,
    /// like a thumb let go of the screen (a quick pass through the centre
    /// keeps it down).
    static let stickRestSeconds = 0.1
    /// Reference height that makes aim sensitivity resolution-independent.
    static let referenceHeight = 1080.0
    static let swipeStepMilliseconds = 8
    /// How quickly a key-driven D-pad glides to its target (time constant):
    /// a thumb pushing the stick, not a jump to the edge.
    static let dpadGlideSeconds = 0.03

    public enum Input: Sendable, Equatable {
        case keyDown(KeyName)
        case keyUp(KeyName)
        case mouseDown(MouseButton)
        case mouseUp(MouseButton)
        /// Raw, unaccelerated mouse delta in counts (pointer locked).
        case mouseMoved(dx: Double, dy: Double)
        /// Cursor movement in display pixels while the pointer is free
        /// (anchor taps follow it; nothing else does).
        case pointerMoved(dx: Double, dy: Double)
        /// Where the free cursor is, in display pixels and not clamped to
        /// the display: MOBA move and smart cast aim at it, and a click's
        /// finger follows it. The host reports it before a press and on every
        /// frame while `isFollowingCursor`; the fingers glide to it on `tick`.
        case cursor(x: Double, y: Double)
        /// A left click that no control takes, as a finger at (x, y) in
        /// display pixels until `fingerUp`. It joins the engine's touches, so
        /// a click while a key holds a touch (the MOBA joystick) is a second
        /// finger of one gesture, not a second stream that also claims
        /// pointer 0 and makes Android drop the held touch.
        case fingerDown(x: Double, y: Double)
        case fingerUp(x: Double, y: Double)
        /// One wheel notch per event; positive scrolls up.
        case scroll(dy: Double)
        case gamepadButton(GamepadButton, pressed: Bool)
        /// Stick position, -1…1, with y up positive (GameController convention).
        case gamepadStick(GamepadStick, x: Double, y: Double)
    }

    public struct Output: Sendable, Equatable {
        public var events: [TouchEvent] = []
        /// The input was handled by a control and must not reach the app as a key or click.
        public var consumed = false
        /// Set when the host should engage (true) or release (false) pointer lock.
        public var pointerLock: Bool?
        /// The mode the layout switched to (its id), for the host to say so.
        public var mode: String?
    }

    public let profile: KeymapProfile
    public let displayID: UInt32
    public private(set) var width: Double
    public private(set) var height: Double
    /// FPS combat mode: the mouse drives the aim control.
    public private(set) var pointerLocked = false
    public private(set) var adsActive = false
    /// The layout's mode now (`KeymapProfile.modes`); nil without modes.
    /// It stays through `reset`: a window losing focus keeps the vehicle.
    public private(set) var mode: String?

    private struct Touch: Sendable {
        let id: Int
        let pointerID: UInt32
        var x: Double
        var y: Double
    }

    private enum Action: Sendable {
        case lift(touch: Int)
        case move(touch: Int, x: Double, y: Double)
        case repeatTap(control: String, trigger: Trigger)
        case macroStep(control: String, index: Int)
    }

    private struct Scheduled: Sendable {
        let time: TimeInterval
        let order: Int
        let action: Action
    }

    private var touches: [Touch] = []
    private var nextTouchID = 1
    private var movedSinceFlush = false
    private var events: [TouchEvent] = []
    private var pressed: Set<Trigger> = []
    /// Touches held by hold, ads, dpad, aim, anchor, MOBA move and smart cast controls.
    private var held: [String: Int] = [:]
    /// Where each held anchor tap's touch is now, and how far it may go from its point, in pixels.
    private var anchors: [String: AnchorTouch] = [:]

    private struct AnchorTouch: Sendable {
        var x: Double
        var y: Double
        let centerX: Double
        let centerY: Double
        /// nil: anywhere on the screen.
        let radius: Double?
    }
    /// When each tap, MOBA move or smart cast went down: it lasts as long
    /// as its key, but never less than tapDurationMilliseconds.
    private var heldSince: [String: TimeInterval] = [:]
    /// Each joystick-like touch (D-pad, MOBA move, smart cast) and the
    /// point it glides to, in pixels.
    private var glides: [String: GlideTouch] = [:]
    /// The free cursor, in pixels, as the host last reported it.
    private var cursor: (x: Double, y: Double)?
    /// The touch of a click that no control took (`fingerDown`).
    private var clickFinger: Int?
    /// A click that a click area kept from the game: its release is taken too.
    private var clickSwallowed = false

    private struct GlideTouch: Sendable {
        var x: Double
        var y: Double
        var targetX: Double
        var targetY: Double
    }
    private var schedule: [Scheduled] = []
    private var scheduleOrder = 0
    private var sticks: [GamepadStick: (x: Double, y: Double)] = [:]
    /// Since when each eye's stick has rested, while its finger is down.
    private var stickRestingSince: [String: TimeInterval] = [:]
    private var lastTick: TimeInterval?

    public init(profile: KeymapProfile, displayID: UInt32, width: Double, height: Double) {
        self.profile = profile
        self.displayID = displayID
        self.width = width
        self.height = height
        mode = profile.firstMode
    }

    // MARK: Public API

    public mutating func handle(_ input: Input, at now: TimeInterval) -> Output {
        var output = Output()
        runDue(until: now)
        switch input {
        case .keyDown(let key): output.consumed = press(.key(key), at: now, output: &output)
        case .keyUp(let key): output.consumed = release(.key(key), at: now)
        case .mouseDown(let button): output.consumed = press(.mouse(button), at: now, output: &output)
        case .mouseUp(let button): output.consumed = release(.mouse(button), at: now)
        case .gamepadButton(let button, true): output.consumed = press(.gamepad(button), at: now, output: &output)
        case .gamepadButton(let button, false): output.consumed = release(.gamepad(button), at: now)
        case .scroll(let dy):
            let trigger: Trigger = dy > 0 ? .scrollUp : .scrollDown
            output.consumed = press(trigger, at: now, output: &output)
            _ = release(trigger, at: now)
        case let .mouseMoved(dx, dy):
            // A held anchor tap takes the mouse; the camera waits.
            if !anchors.isEmpty {
                let scale = height / Self.referenceHeight
                moveAnchors(dx: dx * scale, dy: dy * scale)
                output.consumed = true
            } else if pointerLocked, let camera = fpsAim {
                aim(control: camera, dx: dx, dy: dy, applyCurve: true)
                output.consumed = true
            }
        case let .pointerMoved(dx, dy):
            output.consumed = !anchors.isEmpty
            moveAnchors(dx: dx, dy: dy)
        case let .cursor(x, y):
            cursor = (x, y)
            output.consumed = isFollowingCursor
            for control in controls where control.followsCursor && held[control.id] != nil { aimAtCursor(control, now: false) }
            if let clickFinger { move(clickFinger, x: clampX(x), y: clampY(y)) }
            // Where the fingers go, nothing sent yet: the host reports the
            // cursor on every frame, and `tick` sends one move per frame and
            // glides at one pace whatever the frame rate.
            output.events = takeEvents()
            return output
        case let .fingerDown(x, y):
            output.consumed = true
            // The click areas under it do their actions, and one may keep
            // the click from the game.
            if clickAreas(at: x, y, output: &output) {
                clickSwallowed = true
                break
            }
            if let clickFinger {
                move(clickFinger, x: clampX(x), y: clampY(y))
            } else {
                clickFinger = down(x: clampX(x), y: clampY(y))
            }
        case let .fingerUp(x, y):
            if clickSwallowed {
                clickSwallowed = false
                output.consumed = true
                break
            }
            guard let touch = clickFinger else { break }
            output.consumed = true
            clickFinger = nil
            move(touch, x: clampX(x), y: clampY(y))
            lift(touch)
        case let .gamepadStick(stick, x, y):
            sticks[stick] = (x, y)
            output.consumed = controls.contains { $0.stick == stick }
            for control in profile.controls where control.stick == stick {
                if case .dpad = control.kind { updateDPad(control, smoothly: false) }
            }
        }
        flushMoves()
        output.events = takeEvents()
        return output
    }

    /// Advances timers (taps, swipes, repeats, macros) and gamepad aiming.
    public mutating func tick(at now: TimeInterval) -> [TouchEvent] {
        let dt = lastTick.map { min(max(now - $0, 0), 0.1) } ?? 0
        lastTick = now
        runDue(until: now)
        if dt > 0 { glideAll(fraction: 1 - exp(-dt / Self.dpadGlideSeconds)) }
        if dt > 0 {
            for control in profile.controls where control.stick != nil && isActive(control) {
                guard case .aim = control.kind, let stick = control.stick, let value = sticks[stick] else { continue }
                let d = stickSettings(stick).deflection(x: value.x, y: value.y)
                guard d.x != 0 || d.y != 0 else {
                    restStick(of: control, at: now)
                    continue
                }
                stickRestingSince[control.id] = nil
                aim(control: control, dx: d.x * Self.stickAimSpeed * dt, dy: -d.y * Self.stickAimSpeed * dt, applyCurve: false)
            }
        }
        flushMoves()
        return takeEvents()
    }

    /// Lifts every touch (window lost focus, profile switched).
    public mutating func reset() -> [TouchEvent] {
        schedule.removeAll()
        pressed.removeAll()
        held.removeAll()
        anchors.removeAll()
        heldSince.removeAll()
        glides.removeAll()
        stickRestingSince.removeAll()
        cursor = nil
        clickFinger = nil
        clickSwallowed = false
        adsActive = false
        pointerLocked = false
        flushMoves()
        while let touch = touches.last { lift(touch.id) }
        return takeEvents()
    }

    /// Called by the host when macOS pointer lock is engaged or released
    /// (click into the window, toggle key, focus loss).
    public mutating func setPointerLocked(_ locked: Bool) -> [TouchEvent] {
        guard profile.fps != nil, locked != pointerLocked else { return [] }
        pointerLocked = locked
        // Leave the layer: lift touches of controls that are no longer active.
        // A tap or hold of no layer (out of the mode its own action left:
        // the inventory's button that also frees the mouse) lifts with its key.
        for (controlID, touchID) in held {
            guard let control = profile.controls.first(where: { $0.id == controlID }), !isActive(control) || isFPSAim(control) else { continue }
            switch control.kind {
            case .tap where control.layer == nil, .hold where control.layer == nil: continue
            default: break
            }
            lift(touchID)
            held[controlID] = nil
            anchors[controlID] = nil
            heldSince[controlID] = nil
            glides[controlID] = nil
            if case .ads = control.kind { adsActive = false }
        }
        if !locked { adsActive = false }
        // A click's finger belongs to the cursor, which locking hides and
        // parks (and freeing moves).
        if let clickFinger {
            lift(clickFinger)
            self.clickFinger = nil
        }
        if locked, let camera = fpsAim, isActive(camera), case let .aim(area, _, _, _, _, _, _, origin) = camera.kind {
            let start = touchDown(in: area, at: origin)
            held[camera.id] = down(x: start.x, y: start.y)
        }
        flushMoves()
        return takeEvents()
    }

    public mutating func resize(width: Double, height: Double) -> [TouchEvent] {
        let events = reset()
        self.width = width
        self.height = height
        return events
    }

    public var activeTouchCount: Int { touches.count }

    /// A MOBA move or smart cast is held, or a click's finger is down: they
    /// follow the cursor, so the host reports it on every frame (while a
    /// mouse button is down macOS sends drags, which do not reach the keymap
    /// as moves).
    public var isFollowingCursor: Bool {
        clickFinger != nil || controls.contains { $0.followsCursor && held[$0.id] != nil }
    }

    // MARK: Triggers

    private var controls: [Control] { profile.controls }

    private var fpsAim: Control? {
        guard let id = profile.fps?.aimControl else { return nil }
        return profile.controls.first { $0.id == id }
    }

    private func isFPSAim(_ control: Control) -> Bool { control.id == profile.fps?.aimControl }

    private func stickSettings(_ stick: GamepadStick) -> StickSettings { profile.gamepadSettings[stick] }

    /// The eye's stick rests: its finger lifts once it has rested a moment,
    /// unless the locked mouse holds it (FPS mode keeps that finger down).
    private mutating func restStick(of control: Control, at now: TimeInterval) {
        guard let touch = held[control.id], !(pointerLocked && isFPSAim(control)) else {
            stickRestingSince[control.id] = nil
            return
        }
        let since = stickRestingSince[control.id] ?? now
        stickRestingSince[control.id] = since
        guard now - since >= Self.stickRestSeconds else { return }
        lift(touch)
        held[control.id] = nil
        stickRestingSince[control.id] = nil
    }

    private func isActive(_ control: Control) -> Bool {
        guard control.belongs(to: mode) else { return false }
        guard profile.fps != nil else { return true }
        // Aimed at the cursor, which is hidden and parked while the mouse is locked.
        if control.followsCursor, pointerLocked { return false }
        guard let layer = control.layer else { return true }
        return pointerLocked ? layer == .locked : layer == .cursor
    }

    private mutating func press(_ trigger: Trigger, at now: TimeInterval, output: inout Output) -> Bool {
        // The cursor toggle, and the controls on the same key too (Tab: the
        // game's inventory, and the mouse free to use it).
        var toggled = false
        if let fps = profile.fps, trigger == fps.cursorToggle {
            output.pointerLock = !pointerLocked
            events += setPointerLocked(!pointerLocked)
            toggled = true
        }
        guard !pressed.contains(trigger) || trigger.isMomentary else { return true }
        var matches = controls.filter { isActive($0) && $0.allTriggers.contains(trigger) }
        // With the mouse free, a left click is the player's finger on the
        // game: it fires a control only while the mouse is locked (or for a
        // control made for the cursor, such as moving a MOBA hero by mouse),
        // so the game's own buttons stay clickable.
        if trigger == .mouse(.left), !pointerLocked {
            matches = matches.filter { $0.layer == .cursor || $0.followsCursor }
        }
        // In cursor mode an unbound left click is a normal touch at the cursor (handled by the host).
        guard !matches.isEmpty else { return toggled }
        pressed.insert(trigger)
        // The game's buttons first, then their actions: Enter vehicle is
        // pressed in the mode it belongs to, and lifts with its key.
        for control in matches where control.touchesTheScreen { activate(control, trigger: trigger, at: now) }
        for control in matches { run(control.actions, output: &output) }
        return true
    }

    /// A control's actions, in its order.
    private mutating func run(_ actions: [ControlAction], output: inout Output) {
        for action in actions {
            switch action {
            case .switchMode(let target): enterMode(target, output: &output)
            case .lockMouse: lockPointer(true, output: &output)
            case .freeMouse: lockPointer(false, output: &output)
            case .toggleMouse: lockPointer(!pointerLocked, output: &output)
            }
        }
    }

    /// A click at (x, y) in pixels with the mouse free: the click areas of
    /// this mode under it do their actions, in the layout's order (those
    /// under it as it was clicked: a switch to another mode does not bring
    /// its areas in). True when one of them keeps the click from the game.
    private mutating func clickAreas(at x: Double, _ y: Double, output: inout Output) -> Bool {
        guard !pointerLocked, width > 0, height > 0 else { return false }
        let point = NormalizedPoint(x / width, y / height)
        let hit = controls.filter { control in
            guard case .clickArea(let area, _) = control.kind else { return false }
            return isActive(control) && area.contains(point)
        }
        guard !hit.isEmpty else { return false }
        for control in hit { run(control.actions, output: &output) }
        return hit.contains { if case .clickArea(_, false) = $0.kind { true } else { false } }
    }

    /// The pointer locked to the eye or freed, as the cursor toggle does.
    private mutating func lockPointer(_ lock: Bool, output: inout Output) {
        guard profile.fps != nil, lock != pointerLocked else { return }
        output.pointerLock = lock
        events += setPointerLocked(lock)
    }

    /// Turns the layout to `target`: what the old mode's controls held
    /// lifts (a tap or hold still pressed lifts with its key), the new
    /// mode's D-pads take the keys still held (driving on), and the mouse
    /// does what the mode says.
    private mutating func enterMode(_ target: String, output: inout Output) {
        guard target != mode, let entered = profile.modes.first(where: { $0.id == target }) else { return }
        mode = target
        output.mode = target
        for (controlID, touchID) in held {
            guard let control = controls.first(where: { $0.id == controlID }), !isActive(control) else { continue }
            switch control.kind {
            case .tap, .hold: continue
            default: break
            }
            lift(touchID)
            held[controlID] = nil
            anchors[controlID] = nil
            heldSince[controlID] = nil
            glides[controlID] = nil
            stickRestingSince[controlID] = nil
            if case .ads = control.kind { adsActive = false }
        }
        for control in controls where isActive(control) {
            if case .dpad = control.kind { updateDPad(control, smoothly: false) }
        }
        if let look = entered.mouseLook { lockPointer(look, output: &output) }
    }

    private mutating func release(_ trigger: Trigger, at now: TimeInterval) -> Bool {
        guard pressed.remove(trigger) != nil else {
            return profile.fps?.cursorToggle == trigger
        }
        for control in controls where control.allTriggers.contains(trigger) {
            switch control.kind {
            case .tap, .hold:
                // Still held through another of its triggers.
                guard !control.triggers.contains(where: pressed.contains),
                      let touch = held.removeValue(forKey: control.id) else { continue }
                let earliest = (heldSince.removeValue(forKey: control.id) ?? now) + Double(Self.tapDurationMilliseconds) / 1000
                // A quick press still gives the app a whole tap.
                if now < earliest { enqueue(earliest, .lift(touch: touch)) } else { lift(touch) }
            case .ads(_, let toggle) where !toggle:
                if let touch = held.removeValue(forKey: control.id) { lift(touch) }
                adsActive = false
            case .dpad:
                updateDPad(control)
            case .anchor:
                anchors[control.id] = nil
                if let touch = held.removeValue(forKey: control.id) { lift(touch) }
            case .mobaMove, .smartCast:
                guard !control.triggers.contains(where: pressed.contains),
                      let touch = held.removeValue(forKey: control.id) else { continue }
                // Let go where it is aimed now, not partway through the
                // glide: a skill casts where the finger leaves the screen.
                let aim = glides.removeValue(forKey: control.id)
                let earliest = (heldSince.removeValue(forKey: control.id) ?? now) + Double(Self.tapDurationMilliseconds) / 1000
                if now < earliest {
                    // A quick press still gives the game a whole touch.
                    if let aim { enqueue(earliest, .move(touch: touch, x: aim.targetX / width, y: aim.targetY / height)) }
                    enqueue(earliest, .lift(touch: touch))
                } else {
                    if let aim { move(touch, x: aim.targetX, y: aim.targetY) }
                    lift(touch)
                }
            default:
                break
            }
        }
        return true
    }

    private mutating func activate(_ control: Control, trigger: Trigger, at now: TimeInterval) {
        switch control.kind {
        case .tap(let point), .hold(let point):
            if trigger.isMomentary {
                // A wheel notch has no release: a short tap.
                tap(point, at: now)
            } else if held[control.id] == nil, let touch = down(point) {
                // Down while the key is down, like a finger: a tap or a hold.
                held[control.id] = touch
                heldSince[control.id] = now
            }
        case let .ads(point, toggle):
            if toggle {
                tap(point, at: now)
                adsActive.toggle()
            } else if held[control.id] == nil {
                held[control.id] = down(point)
                adsActive = true
            }
        case .dpad:
            updateDPad(control)
        case .aim:
            break
        case let .swipe(from, to, ms):
            guard let touch = down(from) else { return }
            let steps = max(2, ms / Self.swipeStepMilliseconds)
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let time = now + Double(ms) / 1000 * t
                // Ease in and out, like a finger: slow start, fast middle, slow end.
                let eased = t * t * (3 - 2 * t)
                enqueue(time, .move(touch: touch, x: from.x + (to.x - from.x) * eased, y: from.y + (to.y - from.y) * eased))
            }
            enqueue(now + Double(ms) / 1000, .lift(touch: touch))
        case let .repeatTap(point, interval):
            tap(point, at: now)
            enqueue(now + Double(interval) / 1000, .repeatTap(control: control.id, trigger: trigger))
        case .macro:
            runMacroStep(control, index: 0, at: now)
        case let .anchor(point, radius):
            guard held[control.id] == nil, let touch = down(point) else { return }
            held[control.id] = touch
            anchors[control.id] = AnchorTouch(x: point.x * width, y: point.y * height, centerX: point.x * width,
                                              centerY: point.y * height, radius: radius.map { $0 * height })
        case .mobaMove(let origin, _), .smartCast(let origin, _, _):
            // Down on the joystick or the skill button, then dragged: the
            // game needs the drag to start moving or aiming.
            guard held[control.id] == nil, let touch = down(origin) else { return }
            held[control.id] = touch
            heldSince[control.id] = now
            let x = origin.x * width, y = origin.y * height
            glides[control.id] = GlideTouch(x: x, y: y, targetX: x, targetY: y)
            aimAtCursor(control, now: true)
        case .hotkey, .clickArea:
            // They touch nothing: `press` does their actions.
            break
        }
    }

    /// Drags every held anchor tap by the mouse movement, within its reach
    /// of its point (the whole screen unless it has one) and on the screen.
    private mutating func moveAnchors(dx: Double, dy: Double) {
        for (controlID, var anchor) in anchors {
            guard let touch = held[controlID] else { continue }
            var x = anchor.x + dx, y = anchor.y + dy
            if let radius = anchor.radius {
                let ox = x - anchor.centerX, oy = y - anchor.centerY, distance = hypot(ox, oy)
                if distance > radius, distance > 0 {
                    x = anchor.centerX + ox / distance * radius
                    y = anchor.centerY + oy / distance * radius
                }
            }
            anchor.x = clampX(x)
            anchor.y = clampY(y)
            anchors[controlID] = anchor
            move(touch, x: anchor.x, y: anchor.y)
        }
    }

    private mutating func tap(_ point: NormalizedPoint, at now: TimeInterval) {
        guard let touch = down(point) else { return }
        enqueue(now + Double(Self.tapDurationMilliseconds) / 1000, .lift(touch: touch))
    }

    private mutating func runMacroStep(_ control: Control, index: Int, at now: TimeInterval) {
        guard case .macro(let steps) = control.kind, index < steps.count else { return }
        let step = steps[index]
        switch step {
        case .tap(let point): tap(point, at: now)
        case let .hold(point, ms):
            if let touch = down(point) { enqueue(now + Double(ms) / 1000, .lift(touch: touch)) }
        case .wait: break
        }
        enqueue(now + Double(step.duration) / 1000, .macroStep(control: control.id, index: index + 1))
    }

    // MARK: D-pad

    private mutating func updateDPad(_ control: Control, smoothly: Bool = true) {
        guard case let .dpad(center, radius, up, down, left, right, stick) = control.kind else { return }
        // A direction's key, or the controller's d-pad when it pushes this joystick too.
        func pushed(_ key: Trigger, _ button: GamepadButton) -> Double {
            pressed.contains(key) || (control.dpadButtons && pressed.contains(.gamepad(button))) ? 1 : 0
        }
        var vx = pushed(right, .dpadRight) - pushed(left, .dpadLeft)
        var vy = pushed(down, .dpadDown) - pushed(up, .dpadUp)
        let length = hypot(vx, vy)
        var smooth = smoothly
        if length > 0 {
            vx /= length
            vy /= length
        } else if let stick, let value = sticks[stick] {
            // A real stick is analog already: follow it as it is, past its
            // dead zone, and no further than the rim at a high sensitivity.
            let d = stickSettings(stick).deflection(x: value.x, y: value.y)
            let lean = hypot(d.x, d.y)
            if lean > 0 {
                smooth = false
                let rim = min(1, 1 / lean)
                vx = d.x * rim
                vy = -d.y * rim
            }
        }
        let active = vx != 0 || vy != 0
        if !active || !isActive(control) {
            glides[control.id] = nil
            if let touch = held.removeValue(forKey: control.id) { lift(touch) }
            return
        }
        // Further while its run key is held.
        let reach = control.run.map { pressed.contains($0.trigger) ? $0.scale : 1 } ?? 1
        let radiusPixels = radius * reach * height
        let targetX = center.x * width + vx * radiusPixels
        let targetY = center.y * height + vy * radiusPixels
        if held[control.id] == nil {
            // Touch down at the joystick centre, then drag: dynamic joysticks need the drag.
            guard let touch = self.down(center) else { return }
            held[control.id] = touch
            glides[control.id] = GlideTouch(x: center.x * width, y: center.y * height, targetX: targetX, targetY: targetY)
        } else {
            glides[control.id]?.targetX = targetX
            glides[control.id]?.targetY = targetY
        }
        // Part of the way now (no added latency), the rest over the next frames.
        glide(control.id, fraction: smooth ? 0.45 : 1)
    }

    private mutating func glideAll(fraction: Double) {
        for id in Array(glides.keys) { glide(id, fraction: fraction) }
    }

    private mutating func glide(_ id: String, fraction: Double) {
        guard var glide = glides[id], let touch = held[id] else { return }
        glide.x += (glide.targetX - glide.x) * fraction
        glide.y += (glide.targetY - glide.y) * fraction
        if hypot(glide.targetX - glide.x, glide.targetY - glide.y) < 0.5 {
            glide.x = glide.targetX
            glide.y = glide.targetY
        }
        glides[id] = glide
        move(touch, x: glide.x, y: glide.y)
    }

    // MARK: MOBA (move by mouse, smart cast)

    /// Turns a held MOBA control's finger the way the cursor lies from the
    /// hero, over the next frames (the D-pad's glide). `now` also moves it
    /// part of the way at once, as a D-pad key does: the press itself.
    private mutating func aimAtCursor(_ control: Control, now: Bool) {
        guard glides[control.id] != nil, let target = cursorTarget(for: control) else { return }
        glides[control.id]?.targetX = target.x
        glides[control.id]?.targetY = target.y
        if now { glide(control.id, fraction: 0.45) }
    }

    /// Where a MOBA control's finger belongs for the current cursor, in pixels.
    private func cursorTarget(for control: Control) -> (x: Double, y: Double)? {
        let hero = profile.hero ?? KeymapProfile.defaultHero
        let heroX = hero.x * width, heroY = hero.y * height
        // No cursor yet: aim at the hero itself, so the finger stays put.
        let (cursorX, cursorY) = cursor ?? (heroX, heroY)
        let dx = cursorX - heroX, dy = cursorY - heroY
        let distance = hypot(dx, dy)
        switch control.kind {
        case let .mobaMove(center, radius):
            // Partway while the cursor is close to the hero (no jitter around
            // it), all the way out beyond one radius: the hero runs.
            return offset(from: center, dx: dx, dy: dy, distance: distance, length: min(distance, radius * height))
        case let .smartCast(button, radius, reach):
            // As far as the cursor is from the hero, scaled so that `reach`
            // is a full drag, and clamped to the cast radius.
            let length = min(distance * radius / max(reach, .ulpOfOne), radius * height)
            return offset(from: button, dx: dx, dy: dy, distance: distance, length: length)
        default:
            return nil
        }
    }

    private func clampX(_ x: Double) -> Double { min(max(x, 0), max(width - 1, 0)) }
    private func clampY(_ y: Double) -> Double { min(max(y, 0), max(height - 1, 0)) }

    /// `origin` moved `length` pixels along (dx, dy), shortened if needed to
    /// stay on the screen without changing the direction (skill buttons sit
    /// near the edges).
    private func offset(from origin: NormalizedPoint, dx: Double, dy: Double, distance: Double,
                        length: Double) -> (x: Double, y: Double) {
        let x = origin.x * width, y = origin.y * height
        guard distance > 0, length > 0 else { return (x, y) }
        let ux = dx / distance * length, uy = dy / distance * length
        var t = 1.0
        if x + ux > width - 1 { t = min(t, (width - 1 - x) / ux) }
        if x + ux < 0 { t = min(t, -x / ux) }
        if y + uy > height - 1 { t = min(t, (height - 1 - y) / uy) }
        if y + uy < 0 { t = min(t, -y / uy) }
        t = max(t, 0)
        return (x + ux * t, y + uy * t)
    }

    // MARK: Aim (mouse-look)

    private mutating func aim(control: Control, dx: Double, dy: Double, applyCurve: Bool) {
        guard case let .aim(area, sensitivity, ads, exponent, deadzone, invertY, _, origin) = control.kind, isActive(control) else { return }
        var x = dx, y = dy
        let magnitude = hypot(x, y)
        if applyCurve {
            guard magnitude > deadzone, magnitude > 0 else { return }
            if exponent != 1 {
                let curved = pow(magnitude, exponent)
                x *= curved / magnitude
                y *= curved / magnitude
            }
        }
        let s = adsActive ? ads : sensitivity
        let scale = height / Self.referenceHeight
        var deltaX = x * s.x * scale
        var deltaY = (invertY ? -y : y) * s.y * scale

        let minX = area.minX * width + 1, maxX = area.maxX * width - 1
        let minY = area.minY * height + 1, maxY = area.maxY * height - 1
        guard minX <= maxX, minY <= maxY else { return }
        let start = touchDown(in: area, at: origin)
        if held[control.id] == nil { held[control.id] = down(x: start.x, y: start.y) }

        // Re-centering: when the drag would leave the camera area, finish the
        // drag at the edge, lift, touch down again at the eye's point and
        // carry on with the rest of the movement, so the camera turns without
        // limit. The finger uses the whole area: a tall one lets a look up or
        // down go all the way to its top or bottom before starting over.
        for _ in 0..<8 {
            guard let touchID = held[control.id], let touch = touches.first(where: { $0.id == touchID }) else { return }
            let targetX = touch.x + deltaX, targetY = touch.y + deltaY
            if minX <= targetX && targetX <= maxX && minY <= targetY && targetY <= maxY {
                move(touchID, x: targetX, y: targetY)
                return
            }
            var t = 1.0
            if targetX > maxX { t = min(t, (maxX - touch.x) / deltaX) }
            if targetX < minX { t = min(t, (minX - touch.x) / deltaX) }
            if targetY > maxY { t = min(t, (maxY - touch.y) / deltaY) }
            if targetY < minY { t = min(t, (minY - touch.y) / deltaY) }
            t = max(0, min(t, 1))
            // Already at its point and still unable to go that way (a point
            // on the edge of the area): stay down rather than lift and touch
            // down on the same spot again and again.
            if t == 0, touch.x == start.x, touch.y == start.y { return }
            move(touchID, x: touch.x + deltaX * t, y: touch.y + deltaY * t)
            lift(touchID)
            held[control.id] = down(x: start.x, y: start.y)
            deltaX *= 1 - t
            deltaY *= 1 - t
        }
    }

    /// Where the eye's finger touches down, and touches down again once it
    /// reaches the edge of its area: its point (the centre unless the player
    /// moved it), in pixels, inside the area by the pixel the finger keeps
    /// from its edge.
    private func touchDown(in area: NormalizedRect, at origin: NormalizedPoint?) -> (x: Double, y: Double) {
        let p = origin ?? area.center
        let minX = area.minX * width + 1, maxX = max(area.maxX * width - 1, minX)
        let minY = area.minY * height + 1, maxY = max(area.maxY * height - 1, minY)
        return (min(max(p.x * width, minX), maxX), min(max(p.y * height, minY), maxY))
    }

    // MARK: Scheduling

    private mutating func enqueue(_ time: TimeInterval, _ action: Action) {
        scheduleOrder += 1
        schedule.append(Scheduled(time: time, order: scheduleOrder, action: action))
    }

    private mutating func runDue(until now: TimeInterval) {
        while true {
            let due = schedule.enumerated().filter { $0.element.time <= now }
            guard let next = due.min(by: { ($0.element.time, $0.element.order) < ($1.element.time, $1.element.order) }) else { return }
            schedule.remove(at: next.offset)
            let time = next.element.time
            switch next.element.action {
            case .lift(let touch):
                lift(touch)
            case let .move(touch, x, y):
                move(touch, x: x * width, y: y * height)
            case let .repeatTap(controlID, trigger):
                guard pressed.contains(trigger), let control = controls.first(where: { $0.id == controlID }),
                      case let .repeatTap(point, interval) = control.kind, isActive(control) else { continue }
                tap(point, at: time)
                enqueue(time + Double(interval) / 1000, .repeatTap(control: controlID, trigger: trigger))
            case let .macroStep(controlID, index):
                guard let control = controls.first(where: { $0.id == controlID }) else { continue }
                runMacroStep(control, index: index, at: time)
            }
        }
    }

    // MARK: Touches → MotionEvents

    private mutating func down(_ point: NormalizedPoint) -> Int? { down(x: point.x * width, y: point.y * height) }

    /// A new touch at (x, y) in pixels, on the lowest free pointer id.
    private mutating func down(x: Double, y: Double) -> Int? {
        guard touches.count < KeymapProfile.maxPointers else { return nil }
        flushMoves()
        let used = Set(touches.map(\.pointerID))
        let pointerID = (0..<UInt32(KeymapProfile.maxPointers)).first { !used.contains($0) }!
        let touch = Touch(id: nextTouchID, pointerID: pointerID, x: x, y: y)
        nextTouchID += 1
        touches.append(touch)
        emit(touches.count == 1 ? .down : .pointerDown, index: touches.count - 1)
        return touch.id
    }

    private mutating func move(_ touchID: Int, x: Double, y: Double) {
        guard let index = touches.firstIndex(where: { $0.id == touchID }) else { return }
        guard touches[index].x != x || touches[index].y != y else { return }
        touches[index].x = x
        touches[index].y = y
        movedSinceFlush = true
    }

    private mutating func lift(_ touchID: Int) {
        guard let index = touches.firstIndex(where: { $0.id == touchID }) else { return }
        flushMoves()
        emit(touches.count == 1 ? .up : .pointerUp, index: index)
        touches.remove(at: index)
    }

    private mutating func flushMoves() {
        guard movedSinceFlush, !touches.isEmpty else {
            movedSinceFlush = false
            return
        }
        movedSinceFlush = false
        emit(.move, index: 0)
    }

    private mutating func emit(_ action: TouchAction, index: Int) {
        events.append(TouchEvent(displayID: displayID, action: action, actionIndex: UInt8(index),
                                 pointers: touches.map { TouchPointer(id: $0.pointerID, x: Float($0.x), y: Float($0.y)) }))
    }

    private mutating func takeEvents() -> [TouchEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }
}

extension Control {
    /// The stick that drives a joystick or the eye.
    public var stick: GamepadStick? {
        switch kind {
        case let .dpad(_, _, _, _, _, _, stick): stick
        case let .aim(_, _, _, _, _, _, stick, _): stick
        default: nil
        }
    }
}
