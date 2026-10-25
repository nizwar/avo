import AppKit
import AvoKeymap
import AvoKeymapUI
import AvoKit
import AvoProtocol

/// Shows one Android display and turns Mac input into Input channel records.
///
/// Order of precedence: the keymap (when the app has a profile), then the
/// default translation (click = touch, trackpad scroll = drag, the mouse
/// wheel by the scroll mode, pinch = two fingers, Esc and two-finger swipe
/// left = Back, typing = committed text).
@MainActor
final class DisplayView: NSView, KeymapDisplay, @preconcurrency NSTextInputClient {
    let renderer: MetalRenderer
    var displayID: UInt32 = 0 {
        didSet { pointer = PointerTranslator(displayID: displayID, width: displaySize.width, height: displaySize.height) }
    }
    /// Size of the Android display in pixels.
    private(set) var displaySize = CGSize(width: 1080, height: 2340)
    var send: ((InputRecord) -> Void)?
    var keymap: KeymapController?
    /// Files dragged from Finder onto the window (copied to /sdcard/Download and shared).
    var onDropFiles: (([URL]) -> Void)?
    /// The mouse wheel, by the scroll mode (WheelScrolling.swift).
    private(set) lazy var wheel = WheelScrollController(view: self)

    private var pointer = PointerTranslator(displayID: 0, width: 1080, height: 2340)
    private var pinchTotal = 0.0
    private var marked: NSAttributedString?
    /// Keys whose down event was sent as an Android key event.
    private var keysDown: Set<UInt16> = []

    init(renderer: MetalRenderer) {
        self.renderer = renderer
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        allowedTouchTypes = [.indirect]
        registerForDraggedTypes([.fileURL])
    }

    // MARK: Drag and drop from Finder

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                               options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func makeBackingLayer() -> CALayer { renderer.layer }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var isOpaque: Bool { !renderer.keysOutBlack }

    func setDisplaySize(_ size: CGSize) {
        displaySize = size
        let events = pointer.resize(width: size.width, height: size.height)
        events.forEach { send?(.touch($0)) }
        wheel.displayChanged()
        keymap?.resize(width: size.width, height: size.height)
    }

    override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? 2
        renderer.layer.contentsScale = scale
        // Whole pixels: the renderer and displayRect place the picture in them.
        renderer.layer.drawableSize = CGSize(width: (bounds.width * scale).rounded(), height: (bounds.height * scale).rounded())
        renderer.redraw()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    // MARK: Coordinates

    /// The rect (in view points) where the picture is drawn: the renderer's
    /// own rule (DisplaySizing.presentationRect) for the frame actually on
    /// screen, a held one during a re-plug included, so touches always land
    /// where the picture is.
    var displayRect: CGRect {
        let drawable = renderer.layer.drawableSize
        let source = renderer.frameSize ?? displaySize
        guard drawable.width > 0, drawable.height > 0, source.width > 0, source.height > 0 else { return bounds }
        let r = DisplaySizing.presentationRect(source: PixelSize(source), target: PixelSize(drawable))
        // Pixels (origin top-left) to points (origin bottom-left), per axis.
        let sx = bounds.width / drawable.width, sy = bounds.height / drawable.height
        return CGRect(x: CGFloat(r.x) * sx, y: (drawable.height - CGFloat(r.y + r.height)) * sy,
                      width: CGFloat(r.width) * sx, height: CGFloat(r.height) * sy)
    }

    /// Converts a window location to display pixels (origin top-left).
    func displayPoint(_ locationInWindow: NSPoint) -> (x: Double, y: Double) {
        let point = convert(locationInWindow, from: nil)
        let rect = displayRect
        let x = (point.x - rect.minX) / rect.width * displaySize.width
        let y = (rect.maxY - point.y) / rect.height * displaySize.height
        return (min(max(x, 0), displaySize.width - 1), min(max(y, 0), displaySize.height - 1))
    }

    private func sendTouches(_ events: [TouchEvent]) {
        for event in events { send?(.touch(event)) }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // The wheel's finger lets go before a click's touch.
        wheel.interrupt()
        if keymap?.mouse(.left, down: true) == true { return }
        let p = displayPoint(event.locationInWindow)
        sendTouches(pointer.mouseDown(x: p.x, y: p.y))
    }

    override func mouseDragged(with event: NSEvent) {
        if keymap?.isPointerLocked == true {
            keymap?.lockedMotion(dx: event.deltaX, dy: event.deltaY)
            return
        }
        let p = displayPoint(event.locationInWindow)
        sendTouches(pointer.mouseDragged(x: p.x, y: p.y))
    }

    // Aiming with a button held: the locked mouse's motion (KeymapController).
    override func rightMouseDragged(with event: NSEvent) {
        if keymap?.isPointerLocked == true { keymap?.lockedMotion(dx: event.deltaX, dy: event.deltaY) } else { super.rightMouseDragged(with: event) }
    }

    override func otherMouseDragged(with event: NSEvent) {
        if keymap?.isPointerLocked == true { keymap?.lockedMotion(dx: event.deltaX, dy: event.deltaY) } else { super.otherMouseDragged(with: event) }
    }

    override func mouseUp(with event: NSEvent) {
        if keymap?.mouse(.left, down: false) == true { return }
        let p = displayPoint(event.locationInWindow)
        sendTouches(pointer.mouseUp(x: p.x, y: p.y))
    }

    override func rightMouseDown(with event: NSEvent) { _ = keymap?.mouse(.right, down: true) }
    override func rightMouseUp(with event: NSEvent) { _ = keymap?.mouse(.right, down: false) }

    override func otherMouseDown(with event: NSEvent) {
        if let button = MouseButton(buttonNumber: event.buttonNumber) { _ = keymap?.mouse(button, down: true) }
    }

    override func otherMouseUp(with event: NSEvent) {
        if let button = MouseButton(buttonNumber: event.buttonNumber) { _ = keymap?.mouse(button, down: false) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        // Hover is not a touch. A held anchor tap follows it (KeymapController);
        // pointer-locked aiming uses raw GCMouse deltas instead, and these
        // only for a mouse GameController does not see.
        if keymap?.isPointerLocked == true {
            keymap?.lockedMotion(dx: event.deltaX, dy: event.deltaY)
            return
        }
        let rect = displayRect
        guard let keymap, rect.width > 0, rect.height > 0 else { return }
        // Per axis: a stretched picture (up to 2%) scales each axis its own way.
        _ = keymap.pointerMoved(dx: event.deltaX * displaySize.width / rect.width, dy: event.deltaY * displaySize.height / rect.height)
    }

    // MARK: Trackpad and wheel

    override func scrollWheel(with event: NSEvent) {
        // Scrolling over a window in the background (macOS sends it to the
        // window under the pointer) is the app's, not its key mapping's.
        if window?.isKeyWindow == true, keymap?.scroll(event) == true { return }
        let p = displayPoint(event.locationInWindow)
        // The mouse wheel, and in Mouse Wheel mode the trackpad too, by the
        // scroll mode (WheelScrolling.swift).
        if wheel.handle(event, at: p, touchesBusy: pointer.isActive) { return }
        if event.hasPreciseScrollingDeltas {
            // Momentum events are dropped: Android flings on its own after the finger lifts.
            guard event.momentumPhase.isEmpty else { return }
            let rect = displayRect
            let dx = event.scrollingDeltaX * displaySize.width / max(rect.width, 1)
            let dy = event.scrollingDeltaY * displaySize.height / max(rect.height, 1)
            if event.phase.contains(.began) {
                wheel.interrupt()
                sendTouches(pointer.scroll(phase: .began, x: p.x, y: p.y, dx: dx, dy: dy))
            } else if event.phase.contains(.changed) {
                sendTouches(pointer.scroll(phase: .changed, x: p.x, y: p.y, dx: dx, dy: dy))
            } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                sendTouches(pointer.scroll(phase: .ended, x: p.x, y: p.y, dx: 0, dy: 0))
            }
        }
    }

    override func magnify(with event: NSEvent) {
        let p = displayPoint(event.locationInWindow)
        if event.phase.contains(.began) {
            pinchTotal = 0
            wheel.interrupt()
            sendTouches(pointer.pinch(phase: .began, centerX: p.x, centerY: p.y, magnification: 0))
        }
        pinchTotal += event.magnification
        if event.phase.contains(.changed) {
            sendTouches(pointer.pinch(phase: .changed, centerX: p.x, centerY: p.y, magnification: pinchTotal))
        } else if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            sendTouches(pointer.pinch(phase: .ended, centerX: p.x, centerY: p.y, magnification: pinchTotal))
        }
    }

    /// Spec §1: a two-finger swipe to the left is Back. AppKit reports deltaX
    /// > 0 when the fingers move left ("Swipe between pages" must be on).
    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { sendBack() }
    }

    func sendBack() {
        let back = KeyboardMapping.androidBack
        send?(.key(KeyEvent(displayID: displayID, action: .down, keyCode: back)))
        send?(.key(KeyEvent(displayID: displayID, action: .up, keyCode: back)))
    }

    // MARK: Keyboard

    /// Keys sent as Android key events; everything printable goes through the
    /// input method and arrives as committed text, so every Mac keyboard
    /// layout types the right characters.
    private static let functionalKeys: Set<KeyName> = [
        .returnKey, .tab, .delete, .forwardDelete, .escape, .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    ]

    /// The Android presses for a Mac shortcut in this event (⌘C, ⌥←, ⌘⌫, …).
    private func shortcut(_ key: KeyName, _ flags: NSEvent.ModifierFlags) -> [MacShortcuts.Press]? {
        MacShortcuts.presses(for: key, command: flags.contains(.command), option: flags.contains(.option),
                             shift: flags.contains(.shift), control: flags.contains(.control))
    }

    /// Sends a shortcut's presses (each pressed and released).
    func send(_ presses: [MacShortcuts.Press]) {
        for press in presses {
            sendKey(press.keyCode, down: true, meta: press.metaState, repeatCount: 0)
            sendKey(press.keyCode, down: false, meta: press.metaState, repeatCount: 0)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else {
            interpretKeyEvents([event])
            return
        }
        if keymap?.key(key, down: true, isRepeat: event.isARepeat) == true { return }
        let flags = event.modifierFlags
        if key == .escape {
            if !event.isARepeat { sendBack() }
            return
        }
        if marked == nil, let presses = shortcut(key, flags) {
            send(presses)
            return
        }
        // Any other ⌘ combination belongs to the window (or to nothing).
        if flags.contains(.command) { return }
        // While an input method is composing, every key belongs to it.
        if marked == nil, Self.functionalKeys.contains(key) || flags.contains(.control),
           let code = KeyboardMapping.androidKeyCode(for: key) {
            keysDown.insert(event.keyCode)
            sendKey(code, down: true, meta: meta(flags), repeatCount: event.isARepeat ? 1 : 0)
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else { return }
        if keymap?.key(key, down: false, isRepeat: false) == true { return }
        if keysDown.remove(event.keyCode) != nil, let code = KeyboardMapping.androidKeyCode(for: key) {
            sendKey(code, down: false, meta: meta(event.modifierFlags), repeatCount: 0)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifiers can be keymap triggers (Shift to sprint, Option to toggle the cursor).
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else { return }
        // Read from the event: counting the changes went backwards once another window took one
        // (⇧⌘K: Shift down here, up in the editor), and Shift to run walked while held.
        let down = KeyboardMapping.isModifierDown(key, flags: event.modifierFlags.rawValue)
        _ = keymap?.key(key, down: down, isRepeat: false)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // ⌘ shortcuts with an Android meaning reach Android when this view has
        // focus; the window's own (⌘W, ⌘Q, ⌘G, …) go to the menu.
        if window?.firstResponder === self, event.modifierFlags.contains(.command),
           let key = KeyboardMapping.key(forMacKeyCode: event.keyCode), shortcut(key, event.modifierFlags) != nil {
            keyDown(with: event)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // MARK: Edit menu

    @objc func undo(_ sender: Any?) { sendShortcut(.z) }
    @objc func redo(_ sender: Any?) { sendShortcut(.z, shift: true) }
    @objc func cut(_ sender: Any?) { sendShortcut(.x) }
    @objc func copy(_ sender: Any?) { sendShortcut(.c) }
    @objc func paste(_ sender: Any?) { sendShortcut(.v) }
    @objc override func selectAll(_ sender: Any?) { sendShortcut(.a) }
    @objc func performFindPanelAction(_ sender: Any?) { sendShortcut(.f) }

    private func sendShortcut(_ key: KeyName, shift: Bool = false) {
        if let presses = MacShortcuts.presses(for: key, command: true, option: false, shift: shift, control: false) { send(presses) }
    }

    private func sendKey(_ code: UInt32, down: Bool, meta: UInt32, repeatCount: UInt32) {
        send?(.key(KeyEvent(displayID: displayID, action: down ? .down : .up, keyCode: code, metaState: meta, repeatCount: repeatCount)))
    }

    private func meta(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        KeyboardMapping.androidMetaState(shift: flags.contains(.shift), control: flags.contains(.control),
                                         option: flags.contains(.option), command: false,
                                         capsLock: flags.contains(.capsLock))
    }

    // MARK: NSTextInputClient (typing, dead keys, IME, emoji)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = nil
        guard !text.isEmpty else { return }
        // Split long input into records the Input channel accepts.
        var chunk = ""
        for character in text {
            if (chunk + String(character)).utf8.count > InputWire.maxTextBytes {
                send?(.text(displayID: displayID, chunk))
                chunk = ""
            }
            chunk.append(character)
        }
        if !chunk.isEmpty { send?(.text(displayID: displayID, chunk)) }
    }

    override func doCommand(by selector: Selector) {
        // Editing commands (Return, Delete, arrows) are sent as key events in keyDown;
        // anything else the input method asks for has no Android equivalent.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        if marked?.length == 0 { marked = nil }
    }

    func unmarkText() { marked = nil }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange { marked.map { NSRange(location: 0, length: $0.length) } ?? NSRange(location: NSNotFound, length: 0) }
    func hasMarkedText() -> Bool { marked != nil }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Put IME candidate windows near the bottom of the app, where Android's text fields usually are.
        guard let window else { return .zero }
        let rect = NSRect(x: bounds.midX - 100, y: bounds.minY + 80, width: 200, height: 20)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
