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

    @Test func anEditorWithoutAnInputBindingMustMatchTheCurrentWindow() {
        let client = "mCurClient=ClientState{c4ad1 mUid=10192 mPid=2637 mSelfReportedDisplayId=2}"
        let target = "targetWin=android.os.BinderProxy@abc [dev.editor] targetUserId=0 targetDisplayId=2 clientBindSeq=7"
        let dump = "\(target)\n\(client)\nmFocusedWindow=android.os.BinderProxy@abc"
        #expect(HostAgent.keyboardClientDisplay(dump, pid: nil, package: "dev.editor") == 2)
        #expect(HostAgent.keyboardClientDisplay(dump, pid: nil, package: "dev.other") == nil)
        #expect(HostAgent.keyboardClientDisplay(dump, pid: 263, package: "dev.editor") == nil)
        #expect(HostAgent.keyboardClientDisplay(dump + "\nmFocusedWindow=android.os.BinderProxy@def", pid: nil, package: "dev.editor") == nil)
        let moved = target.replacingOccurrences(of: "targetDisplayId=2", with: "targetDisplayId=12")
        #expect(HostAgent.keyboardClientDisplay(dump + "\n\(moved)", pid: nil, package: "dev.editor") == nil)
        #expect(HostAgent.keyboardClientDisplay(client, pid: nil, package: "dev.editor") == nil)
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
