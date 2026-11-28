import AvoKit
import Testing
@testable import AvoDaemonCore

struct AvoInputRoutingTests {
    @Test func onlyTheFocusedClientIdentifiesTheEditorDisplay() {
        let row = "  mCurClient=ClientState{c4ad1 mUid=10192 mPid=2637 mSelfReportedDisplayId=12}"
        #expect(HostAgent.keyboardClientDisplay(row, pid: 2637) == 12)
        #expect(HostAgent.keyboardClientDisplay(row, pid: 263) == nil)
        #expect(HostAgent.keyboardClientDisplay("mCurTokenDisplayId=0", pid: 2637) == nil)
    }

    @Test func physicalKeysKeepLayoutAndModifierSides() {
        #expect(PhysicalKeyboard.extra[0x0a]?.scan == 86) // ISO extra key
        #expect(PhysicalKeyboard.extra[0x66]?.scan == 123 && PhysicalKeyboard.extra[0x68]?.scan == 122) // Eisu, Kana
        #expect(PhysicalKeyboard.extra[0x4c]?.scan == 96 && PhysicalKeyboard.linux[66] == 28) // keypad and main Return
        #expect(AndroidKeys.modifiers(in: 0x02).map(\.linux) == [56])
        #expect(AndroidKeys.modifiers(in: 0x22).map(\.linux) == [100])
        #expect(AndroidKeys.modifiers(in: 0x32).map(\.linux) == [56, 100])
    }
}
