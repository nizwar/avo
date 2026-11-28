import AvoIO
import AvoTestSupport
import Foundation
import Synchronization
import Testing
@testable import AvoDaemonCore
@testable import AvoKit

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

    @Test(arguments: [true, false])
    func pasteUsesTheLatestSharedClipboard(sharing: Bool) async throws {
        let clipboard = PendingClipboard()
        let clipboardAtEdit = Mutex<[String]>([])
        let app = FakeBridgeAgent.app("dev.editor", label: "Editor")
        let harness = try Harness(apps: [app], configure: { $0.shareClipboard = sharing }, wrap: { base in
            ClipboardInputEngine(base: base) { copied in clipboardAtEdit.withLock { $0.append(copied) } }
        }, clipboard: clipboard)
        defer { harness.cleanUp() }
        await harness.core.start()
        let (shim, _) = await harness.connect(.shim(package: app.package))
        let request = OpenDisplayRequest(package: app.package, width: 800, height: 1000, dpi: 320)
        let display = try await harness.core.openDisplay(request, client: shim)
        clipboard.pending.withLock { $0 = "fresh copy" }
        let commit = AvoInputEdit(session: "editor", sequence: 1, action: .commit, text: "汉")
        await harness.core.editText(commit, display: display, client: shim)
        #expect(clipboard.pending.withLock { $0 } == "fresh copy")
        let paste = AvoInputEdit(session: "editor", sequence: 2, action: .keyDown, keyCode: 50, metaState: 0x3000)
        await harness.core.editText(paste, display: display, client: shim)
        #expect(clipboardAtEdit.withLock { $0 } == ["", sharing ? "fresh copy" : ""])
        #expect(clipboard.pending.withLock { $0 } == (sharing ? nil : "fresh copy"))
    }
}

private final class PendingClipboard: ClipboardBridge {
    let pending = Mutex<String?>(nil)
    func start(onChange: @escaping @Sendable (String) -> Void) {}
    func set(_ text: String) {}
    func takeChange() -> String? {
        pending.withLock { value in
            defer { value = nil }
            return value
        }
    }
}

/// Records the Android clipboard at the moment an edit reaches the engine.
private final class ClipboardInputEngine: AvoInputEngine {
    let base: FakeEngine
    let onEdit: @Sendable (String) -> Void
    init(base: FakeEngine, onEdit: @escaping @Sendable (String) -> Void) {
        self.base = base
        self.onEdit = onEdit
    }
    let avoInputEditorUpdates = AsyncStream<(UInt32, AvoInputEditorState?)> { $0.finish() }
    var name: String { base.name }
    var exits: AsyncStream<EngineExit> { base.exits }
    func start(_ launch: EngineLaunch) async throws { try await base.start(launch) }
    func stop() async { await base.stop() }
    func snapshot(to url: URL) async throws { try await base.snapshot(to: url) }
    func connect(port: UInt32) async throws -> any ByteStream { try await base.connect(port: port) }
    func editText(_ edit: AvoInputEdit, display: UInt32) async {
        let copies = await base.agent.requests { if case .setClipboard(let clip) = $0 { clip.text } else { nil } }
        onEdit(copies.last ?? "")
    }
}
