import Testing
@testable import AvoDaemonCore

/// Delivery of each committed TEXT record while an Android input method is active.
struct AndroidKeysTextTests {
    @Test(arguments: ["n", "i", " ", "1", "Hello, world! 42"])
    func ordinaryTypingReachesTheAndroidKeyboard(_ text: String) {
        #expect(AndroidKeys.canTypeAsKeys(text))
    }

    @Test(arguments: ["你好", "AI助手 2.0", "你OK好", "é", "こんにちは", "안녕", "a🥑b"])
    func macCandidateIsCommittedInOnePiece(_ text: String) {
        #expect(!AndroidKeys.canTypeAsKeys(text))
    }
}
