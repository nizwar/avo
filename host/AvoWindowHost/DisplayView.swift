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
    var sendEdit: ((AvoInputEdit) -> Void)?
    private var editor = AvoInputTextBuffer()
    private var usesStockInputRouting = false
    private var physicalKeyboard: Bool { usesStockInputRouting && editor.state == nil }
    private var discardingMarkedText = false
    var keymap: KeymapController?
    /// Files dragged from Finder onto the window (copied to /sdcard/Download and shared).
    var onDropFiles: (([URL]) -> Void)?
    /// The mouse wheel, by the scroll mode (WheelScrolling.swift).
    private(set) lazy var wheel = WheelScrollController(view: self)

    private var pointer = PointerTranslator(displayID: 0, width: 1080, height: 2340)
    private var pinchTotal = 0.0
    private var marked: NSAttributedString?
    /// Keys whose down event was sent as an Android key event.
    private var keysDown: [UInt16: (code: UInt32, scan: UInt32)] = [:]
    /// The left button went down beside the picture: the press moves the
    /// window, and nothing of it reaches Android.
    private var movingWindow = false

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
        Self.sharesFiles(Self.draggedFiles(sender)) ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = Self.draggedFiles(sender)
        guard Self.sharesFiles(urls) else { return false }
        onDropFiles?(urls)
        return true
    }

    private static func draggedFiles(_ sender: any NSDraggingInfo) -> [URL] {
        sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    /// Only files go to Android, each copied to its Downloads folder
    /// (DaemonCore.shareFiles): a drop with a folder in it is refused, on
    /// the window as on the app's Dock icon.
    static func sharesFiles(_ urls: [URL]) -> Bool {
        !urls.isEmpty && !urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
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

    /// Focus left the game (the window resigned key, went to the background
    /// or into Picture in Picture, or closed), and the key-ups and mouse-ups
    /// still to come go elsewhere: every key sent down as an Android key
    /// event goes up, and the pointer's and the wheel's fingers lift, so
    /// nothing stays pressed in Android. The key mapping lets go of its own
    /// (KeymapController.focusLost).
    func releaseAll() {
        for (_, key) in keysDown.sorted(by: { $0.key < $1.key }) {
            sendKey(key.code, down: false, meta: 0, repeatCount: 0, scan: key.scan)
        }
        if usesStockInputRouting {
            if hasMarkedText() { sendEditor(.cancel) }
            resetMacComposition()
        }
        keysDown.removeAll()
        sendTouches(pointer.cancel())
        wheel.interrupt()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        // The wheel's finger lets go before a click's touch.
        wheel.interrupt()
        if keymap?.mouse(.left, down: true) == true { return }
        // The bars beside a frame that does not fill the window move it
        // (DisplaySizing.movesWindow); only the picture is Android's.
        movingWindow = DisplaySizing.movesWindow(at: convert(event.locationInWindow, from: nil), picture: displayRect)
        if movingWindow {
            window?.performDrag(with: event)
            return
        }
        let p = displayPoint(event.locationInWindow)
        sendTouches(pointer.mouseDown(x: p.x, y: p.y))
    }

    override func mouseDragged(with event: NSEvent) {
        if keymap?.isPointerLocked == true {
            keymap?.lockedMotion(dx: event.deltaX, dy: event.deltaY)
            return
        }
        if movingWindow { return }
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
        if movingWindow {
            movingWindow = false
            return
        }
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

    /// When macOS handles composition, these keys still go to Android as key events.
    private static let functionalKeys: Set<KeyName> = [
        .returnKey, .tab, .delete, .forwardDelete, .escape, .up, .down, .left, .right,
        .home, .end, .pageUp, .pageDown, .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12,
    ]

    /// Keep edits and the keys that change an editor's contents or selection in order.
    private static let editorKeyCodes = Set([
        KeyName.left, .right, .up, .down, .home, .end, .pageUp, .pageDown,
        .delete, .forwardDelete, .returnKey, .tab, .a, .c, .v, .x, .y, .z,
    ].compactMap { KeyboardMapping.androidKeyCode(for: $0) })

    /// The Android presses for a Mac shortcut in this event (⌘C, ⌥←, ⌘⌫, …).
    private func shortcut(_ key: KeyName, _ flags: NSEvent.ModifierFlags) -> [MacShortcuts.Press]? {
        MacShortcuts.presses(for: key, command: flags.contains(.command), option: flags.contains(.option),
                             shift: flags.contains(.shift), control: flags.contains(.control))
    }

    @discardableResult
    private func sendShortcut(_ key: KeyName, flags: NSEvent.ModifierFlags = .command) -> Bool {
        guard let presses = shortcut(key, flags) else { return false }
        let keepsComposition = key == .c || (key == .x && selectedRange().length == 0)
        if usesStockInputRouting, hasMarkedText(), !keepsComposition {
            // Paste follows the marked text even when the input method has selected a candidate.
            // Other editing commands, including Cut, operate on the current selection.
            if key == .v, let marked { sendEditor(.commit, text: marked.string) }
            else { sendEditor(.finish) }
            resetMacComposition()
        }
        for press in presses {
            sendKey(press.keyCode, down: true, meta: press.metaState, repeatCount: 0)
            sendKey(press.keyCode, down: false, meta: press.metaState, repeatCount: 0)
        }
        return true
    }

    func avoInputEditorChanged(_ state: AvoInputEditorState?) {
        let changedSession = editor.state?.session != state?.session || !usesStockInputRouting
        let hadMark = editor.marked != nil
        editor.update(state)
        if changedSession || hadMark && editor.marked == nil && marked != nil {
            resetMacComposition()
        }
        usesStockInputRouting = true
    }

    private func resetMacComposition() {
        discardingMarkedText = true
        marked = nil
        inputContext?.discardMarkedText()
        discardingMarkedText = false
    }

    private func sendEditor(_ action: AvoInputEdit.Action, text: String? = nil,
                            caret: NSRange? = nil, replacement: NSRange? = nil) {
        guard !discardingMarkedText,
              let edit = editor.edit(action, text: text, selection: caret, replacement: replacement) else { return }
        sendEdit?(edit)
    }

    private func keyDown(_ event: NSEvent, code: UInt32, scan: UInt32 = 0) {
        keysDown[event.keyCode] = (code, scan)
        let repeated = event.type == .keyDown && event.isARepeat
        sendKey(code, down: true, meta: meta(event.modifierFlags), repeatCount: repeated ? 1 : 0, scan: scan)
    }

    override func keyDown(with event: NSEvent) {
        let key = KeyboardMapping.key(forMacKeyCode: event.keyCode)
        let flags = event.modifierFlags
        if let key, keymap?.key(key, down: true, isRepeat: event.isARepeat) == true { return }
        if key == .escape && (!usesStockInputRouting || !hasMarkedText()) {
            if !event.isARepeat { sendBack() }
            return
        }
        let forwardsShortcut = (usesStockInputRouting && flags.contains(.command)) || (!physicalKeyboard && !hasMarkedText())
        if let key, forwardsShortcut, sendShortcut(key, flags: flags) { return }
        // Any other ⌘ combination belongs to the window (or to nothing).
        if flags.contains(.command) { return }
        if physicalKeyboard {
            if let extra = PhysicalKeyboard.extra[event.keyCode] {
                keyDown(event, code: extra.code, scan: UInt32(extra.scan))
            } else if let code = KeyboardMapping.androidKeyCode(forMacKeyCode: event.keyCode), let scan = PhysicalKeyboard.linux[code] {
                keyDown(event, code: code, scan: UInt32(scan))
            }
            return
        }
        // While an input method is composing, every key belongs to it.
        if let key, !hasMarkedText(), Self.functionalKeys.contains(key) || flags.contains(.control),
           let code = KeyboardMapping.androidKeyCode(for: key) {
            keyDown(event, code: code)
            return
        }
        interpretKeyEvents([event])
    }

    override func keyUp(with event: NSEvent) {
        if let key = KeyboardMapping.key(forMacKeyCode: event.keyCode),
           keymap?.key(key, down: false, isRepeat: false) == true { return }
        if let sent = keysDown.removeValue(forKey: event.keyCode) {
            sendKey(sent.code, down: false, meta: meta(event.modifierFlags), repeatCount: 0, scan: sent.scan)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Modifiers can be keymap triggers (Shift to sprint, Option to toggle the cursor).
        guard let key = KeyboardMapping.key(forMacKeyCode: event.keyCode) else { return }
        // Read from the event: counting the changes went backwards once another window took one
        // (⇧⌘K: Shift down here, up in the editor), and Shift to run walked while held.
        let down = KeyboardMapping.isModifierDown(key, flags: event.modifierFlags.rawValue)
        if keymap?.key(key, down: down, isRepeat: false) == true { return }
        if key == .capsLock, physicalKeyboard {
            sendKey(115, down: true, meta: 0, repeatCount: 0, scan: 58)
            sendKey(115, down: false, meta: 0, repeatCount: 0, scan: 58)
        } else if !down, let sent = keysDown.removeValue(forKey: event.keyCode) {
            sendKey(sent.code, down: false, meta: meta(event.modifierFlags), repeatCount: 0, scan: sent.scan)
        } else if physicalKeyboard, key != .command && key != .rightCommand,
                  let code = KeyboardMapping.androidKeyCode(for: key), let scan = PhysicalKeyboard.linux[code] {
            if down { keyDown(event, code: code, scan: UInt32(scan)) }
            else { sendKey(code, down: false, meta: meta(event.modifierFlags), repeatCount: 0, scan: UInt32(scan)) }
        }
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
    @objc func redo(_ sender: Any?) { sendShortcut(.z, flags: [.command, .shift]) }
    @objc func cut(_ sender: Any?) { sendShortcut(.x) }
    @objc func copy(_ sender: Any?) { sendShortcut(.c) }
    @objc func paste(_ sender: Any?) { sendShortcut(.v) }
    @objc override func selectAll(_ sender: Any?) { sendShortcut(.a) }
    @objc func performFindPanelAction(_ sender: Any?) { sendShortcut(.f) }

    private func sendKey(_ code: UInt32, down: Bool, meta: UInt32, repeatCount: UInt32, scan: UInt32 = 0) {
        if scan == 0, let sendEdit, Self.editorKeyCodes.contains(code),
           let edit = editor.key(code, down: down, meta: meta, repeatCount: repeatCount) {
            sendEdit(edit)
            return
        }
        send?(.key(KeyEvent(displayID: displayID, action: down ? .down : .up, keyCode: code, metaState: meta, repeatCount: repeatCount, scanCode: scan)))
    }

    private func meta(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var value = KeyboardMapping.androidMetaState(shift: flags.contains(.shift), control: flags.contains(.control),
                                                      option: flags.contains(.option), command: false,
                                                      capsLock: flags.contains(.capsLock))
        if physicalKeyboard && flags.rawValue & 0x207f != 0 {
            // Android layouts can assign a different character to right Option (AltGr).
            // Events without NX device-side bits use the ordinary left modifier.
            for (left, right, l, r): (KeyName, KeyName, UInt32, UInt32) in [
                (.shift, .rightShift, 0x40, 0x80), (.option, .rightOption, 0x10, 0x20),
                (.control, .rightControl, 0x2000, 0x4000),
            ] {
                if KeyboardMapping.isModifierDown(right, flags: flags.rawValue) {
                    value |= r
                    if !KeyboardMapping.isModifierDown(left, flags: flags.rawValue) { value &= ~l }
                }
            }
        }
        return value
    }

    // MARK: NSTextInputClient (typing, dead keys, IME, emoji)

    func insertText(_ string: Any, replacementRange: NSRange) {
        guard !discardingMarkedText else { return }
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        marked = nil
        if usesStockInputRouting {
            sendEditor(.commit, text: text, replacement: replacementRange)
            return
        }
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
        if usesStockInputRouting, selector == #selector(NSResponder.cancelOperation(_:)), hasMarkedText() {
            sendEditor(.cancel)
            marked = nil
        }
        // Editing commands (Return, Delete, arrows) are sent as key events in keyDown;
        // anything else the input method asks for has no Android equivalent.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard !discardingMarkedText else { return }
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: (string as? String) ?? "")
        sendEditor(.mark, text: marked?.string ?? "", caret: selectedRange, replacement: replacementRange)
        if marked?.length == 0 { marked = nil }
    }

    func unmarkText() {
        if usesStockInputRouting && hasMarkedText() { sendEditor(.finish) }
        marked = nil
    }
    func selectedRange() -> NSRange { editor.selection ?? NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
        if !usesStockInputRouting, let marked { return NSRange(location: 0, length: marked.length) }
        return editor.marked ?? NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked != nil || editor.marked != nil }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard let (text, shared) = editor.substring(range) else { return nil }
        actualRange?.pointee = shared
        return NSAttributedString(string: text)
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Put IME candidate windows near the bottom of the app, where Android's text fields usually are.
        guard let window else { return .zero }
        let rect = NSRect(x: bounds.midX - 100, y: bounds.minY + 80, width: 200, height: 20)
        return window.convertToScreen(convert(rect, to: nil))
    }
}
