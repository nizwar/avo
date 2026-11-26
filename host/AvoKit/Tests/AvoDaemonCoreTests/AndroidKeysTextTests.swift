import Testing
@testable import AvoDaemonCore

/// How input-method text is split between key presses and a paste (issue #22).
struct AndroidKeysTextTests {
    private func runs(_ text: String) -> [String] {
        AndroidKeys.textRuns(text).map { ($0.typed ? "keys:" : "paste:") + $0.text }
    }

    @Test func plainTextIsTyped() {
        #expect(runs("Hello, world! 42") == ["keys:Hello, world! 42"])
    }

    @Test func chineseIsPasted() {
        #expect(runs("你好") == ["paste:你好"])
    }

    @Test func mixedTextKeepsItsOrder() {
        #expect(runs("ok 你好 ok") == ["keys:ok ", "paste:你好", "keys: ok"])
    }

    @Test func accentsKanaHangulAndEmojiArePasted() {
        #expect(runs("é") == ["paste:é"])
        #expect(runs("こんにちは") == ["paste:こんにちは"])
        #expect(runs("안녕") == ["paste:안녕"])
        #expect(runs("a🥑b") == ["keys:a", "paste:🥑", "keys:b"])
    }

    @Test func emptyTextHasNoRuns() {
        #expect(AndroidKeys.textRuns("").isEmpty)
    }
}
