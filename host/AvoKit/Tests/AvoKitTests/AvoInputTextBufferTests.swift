import Foundation
import Testing
@testable import AvoKit

struct AvoInputTextBufferTests {
    private func snapshot(_ text: String, session: String = "one") -> AvoInputEditorState {
        AvoInputEditorState(session: session, ack: 0, start: text.utf16.count, end: text.utf16.count,
                            markStart: -1, markEnd: -1, offset: 0, text: text)
    }

    @Test func replacesAndComposesUsingAbsoluteUTF16Positions() throws {
        var buffer = AvoInputTextBuffer()
        let emoji = "👩🏽‍💻"
        let initial = snapshot("A" + emoji + "B")
        buffer.update(initial)
        let range = NSRange(location: 1, length: emoji.utf16.count)
        let pendingMark = buffer.edit(.mark, text: "にほ", selection: NSRange(location: 1, length: 0), replacement: range)
        let mark = try #require(pendingMark)
        #expect(mark.from == 1 && mark.to == NSMaxRange(range) && mark.caretStart == 1)
        #expect(buffer.selection == NSRange(location: 2, length: 0))
        #expect(buffer.marked == NSRange(location: 1, length: 2))
        buffer.update(initial)
        #expect(buffer.substring(NSRange(location: 0, length: 100))?.0 == "AにほB")
        let pendingCommit = buffer.edit(.commit, text: "日本")
        let commit = try #require(pendingCommit)
        #expect(commit.sequence == 2 && commit.from == nil && commit.to == nil)
        #expect(buffer.state?.text == "A日本B" && buffer.marked == nil)
    }

    @Test func cancelAndFinishRespectTheCurrentEditor() {
        var buffer = AvoInputTextBuffer()
        buffer.update(snapshot("م"))
        _ = buffer.edit(.mark, text: "e\u{301}")
        _ = buffer.edit(.cancel)
        #expect(buffer.state?.text == "م")
        _ = buffer.edit(.mark, text: "한")
        _ = buffer.edit(.finish)
        #expect(buffer.state?.text == "م한" && buffer.marked == nil)
        buffer.update(nil)
        #expect(buffer.edit(.commit, text: "old") == nil)
        buffer.update(snapshot("אב", session: "two"))
        let edit = buffer.edit(.commit, text: "ג")
        #expect(edit?.session == "two" && edit?.sequence == 1)
        #expect(buffer.state?.text == "אבג")
    }

    @Test func editingKeysShareTheTextSequenceWithoutPredictingTheSelection() {
        var buffer = AvoInputTextBuffer()
        buffer.update(snapshot("AB"))
        let down = buffer.key(21, down: true, meta: 0x41, repeatCount: 1)
        let up = buffer.key(21, down: false, meta: 0, repeatCount: 0)
        #expect(down?.sequence == 1 && down?.action == .keyDown && down?.keyCode == 21)
        #expect(down?.metaState == 0x41 && down?.repeatCount == 1)
        #expect(up?.sequence == 2 && up?.action == .keyUp)
        #expect(buffer.state?.text == "AB" && buffer.selection == NSRange(location: 2, length: 0))
        let commit = buffer.edit(.commit, text: "汉")
        #expect(commit?.sequence == 3 && commit?.from == nil && commit?.to == nil)
    }

    @Test func privateEditorsDropCachedAndOptimisticContext() {
        var buffer = AvoInputTextBuffer()
        var field = snapshot("existing")
        buffer.update(field)
        field.privateEditor = true
        field.text = nil
        field.offset = nil
        buffer.update(field)
        #expect(buffer.state?.text == nil)
        _ = buffer.edit(.mark, text: "秘密")
        #expect(buffer.state?.text == nil && buffer.state?.offset == nil)
        #expect(buffer.marked == NSRange(location: 8, length: 2))
        let candidate = buffer.edit(.commit, text: "x", replacement: NSRange(location: 8, length: 2))
        #expect(candidate?.afterMark == 1 && candidate?.from == nil && candidate?.basis == nil)
    }

    @Test func anAbsoluteReplacementCarriesTheViewFromWhichAppKitChoseIt() throws {
        var buffer = AvoInputTextBuffer()
        var field = snapshot("AB")
        field.start = 1
        field.end = 1
        buffer.update(field)
        let firstEdit = buffer.edit(.commit, text: "xy")
        let first = try #require(firstEdit)
        #expect(first.basis == nil && buffer.state?.ack == 0)
        var receipt = field
        receipt.ack = 1
        receipt.start = 3
        receipt.end = 3
        receipt.text = nil
        receipt.offset = nil
        receipt.contextPending = true
        buffer.update(receipt)
        let replacement = buffer.edit(.commit, text: "中", replacement: NSRange(location: 2, length: 1))
        let next = try #require(replacement)
        let basis = try #require(next.basis)
        #expect(basis.text == "AxyB" && basis.offset == 0 && basis.start == 3 && basis.end == 3)
        #expect(next.sequence == 2 && next.from == 2 && next.to == 3)
        field.ack = 2
        field.text = "AxB"
        field.start = 2
        field.end = 2
        buffer.update(field)
        #expect(buffer.substring(NSRange(location: 0, length: 3))?.0 == "AxB")
        field.text = nil
        field.offset = nil
        buffer.update(field)
        let unidentified = buffer.edit(.mark, text: "a", replacement: NSRange(location: 1, length: 1))
        #expect(unidentified?.from == 1 && unidentified?.basis == nil)
        let candidate = buffer.edit(.commit, text: "界")
        #expect(candidate?.sequence == 4 && candidate?.afterMark == unidentified?.sequence)
    }

    @Test func aRestartDropsOldContextAndKeepsPendingEditsInSequence() {
        var buffer = AvoInputTextBuffer()
        let original = snapshot("AB")
        buffer.update(original)
        _ = buffer.edit(.mark, text: "xy")
        var restarted = snapshot("new")
        restarted.generation = 1
        buffer.update(restarted)
        #expect(buffer.marked == nil && buffer.state?.text == "new")
        var late = original
        late.ack = 1
        buffer.update(late)
        let edit = buffer.edit(.commit, text: "界", replacement: NSRange(location: 0, length: 1))
        #expect(edit?.session == original.session && edit?.sequence == 2 && edit?.basis?.generation == 1)
    }

    @Test(arguments: ["LL", "e\u{301}"])
    func aLongMarkedSelectionIsReadableBeforeTheEditorAcknowledgesIt(paddingBoundary: String) throws {
        var buffer = AvoInputTextBuffer()
        let left = String(repeating: "L", count: 255) + paddingBoundary + String(repeating: "L", count: 255)
        buffer.update(snapshot(left + String(repeating: "R", count: 512)))
        let text = String(repeating: "🙂", count: 768)
        let entireMark = NSRange(location: 0, length: text.utf16.count)
        let range = NSRange(location: 512, length: text.utf16.count)
        let mark = buffer.edit(.mark, text: text, selection: entireMark,
                               replacement: NSRange(location: range.location, length: 0))
        _ = try #require(mark)
        #expect(buffer.selection == range)
        let (selected, actual) = try #require(buffer.substring(range))
        try #require(actual == range)
        #expect(selected == text)
        let context = try #require(buffer.state?.text)
        #expect(context.utf16.count <= 2048)
    }

    @Test func longCommitsKeepTheirContentsAndBoundTheContext() throws {
        var buffer = AvoInputTextBuffer()
        buffer.update(snapshot(""))
        let text = String(repeating: "👩🏽‍💻", count: 1200)
        let pending = buffer.edit(.commit, text: text)
        let edit = try #require(pending)
        #expect(edit.text == text)
        #expect(buffer.selection == NSRange(location: text.utf16.count, length: 0))
        let (tail, range) = try #require(buffer.substring(NSRange(location: 0, length: text.utf16.count)))
        #expect(text.hasSuffix(tail) && tail.utf16.count <= 2048 && NSMaxRange(range) == text.utf16.count)
        #expect(buffer.edit(.commit, text: "x", replacement: NSRange(location: Int(Int32.max), length: 1)) == nil)
        #expect(buffer.edit(.commit, text: String(repeating: "\0", count: 1_400_000)) == nil)
        #expect(buffer.edit(.commit, text: "y")?.sequence == 2)
    }
}
