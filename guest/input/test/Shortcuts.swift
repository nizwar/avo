import AppKit
@testable import AvoKit
@testable import AvoWindowHost

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                      styleMask: [.titled], backing: .buffered, defer: true)
let view = DisplayView(renderer: MetalRenderer()!)
window.contentView = view
precondition(window.makeFirstResponder(view))

@MainActor
func check(_ letter: String, macKey: UInt16, androidKey: UInt32, action: Selector,
           selection: NSRange = NSRange(location: 0, length: 2), beforeKey: AvoInputEdit.Action?) {
    for menu in [false, true] {
        let session = "\(letter)-\(selection)-\(menu ? "menu" : "keyboard")"
        view.avoInputEditorChanged(AvoInputEditorState(session: session, ack: 0, start: 1, end: 1,
                                                       markStart: -1, markEnd: -1, offset: 0, text: "AB"))
        var edits: [AvoInputEdit] = []
        view.sendEdit = { edits.append($0) }
        view.setMarkedText("かな", selectedRange: selection,
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        if menu {
            precondition(app.sendAction(action, to: view, from: nil))
        } else {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                         characters: letter, charactersIgnoringModifiers: letter,
                                         isARepeat: false, keyCode: macKey)!
            precondition(view.performKeyEquivalent(with: event))
        }
        let expected: [AvoInputEdit.Action] = [.mark] + [beforeKey].compactMap { $0 } + [.keyDown, .keyUp]
        precondition(edits.map(\.action) == expected, session)
        precondition(edits.suffix(2).allSatisfy { $0.keyCode == androidKey && ($0.metaState ?? 0) & 0x1000 != 0 }, session)
        precondition(view.hasMarkedText() == (beforeKey == nil), session)
        if beforeKey == .commit {
            precondition(edits[1].text == "かな" && view.selectedRange() == NSRange(location: 3, length: 0), session)
        }
    }
}
check("v", macKey: 9, androidKey: 50, action: #selector(DisplayView.paste(_:)), beforeKey: .commit)
check("a", macKey: 0, androidKey: 29, action: #selector(DisplayView.selectAll(_:)), beforeKey: .finish)
check("c", macKey: 8, androidKey: 31, action: #selector(DisplayView.copy(_:)), beforeKey: nil)
check("x", macKey: 7, androidKey: 52, action: #selector(DisplayView.cut(_:)), beforeKey: .finish)
check("x", macKey: 7, androidKey: 52, action: #selector(DisplayView.cut(_:)),
      selection: NSRange(location: 2, length: 0), beforeKey: nil)
print("Avo Input Mac shortcut tests passed")
