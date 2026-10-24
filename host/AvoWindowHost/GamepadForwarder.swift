import AppKit
import AvoKeymap
import AvoKeymapUI
import AvoProtocol
import GameController

/// Hands the Mac's game controller to Android as a real gamepad, for games
/// with controller support: the key window sends its state as GAMEPAD
/// records, which the daemon plays on the engine's Xbox pad (HostAgent's
/// gamepad section). One per process: GameController gives a controller's
/// input to the app in front, and one of its windows is key.
///
/// A window whose key mapping uses the gamepad (Game Mode with gamepad
/// controls, KeymapController) keeps it for touches, and so does a window
/// whose key mapping editor is open (its buttons are being bound). Android
/// has no gamepad then, so the game does not switch to controller prompts
/// the mapping would fight.
@MainActor
final class GamepadForwarder {
    static let shared = GamepadForwarder()

    /// A window that can drive the gamepad.
    private struct Window {
        let id: ObjectIdentifier
        /// Sends a GAMEPAD record naming the window's display.
        let send: (GamepadState) -> Void
        let mappingTakesGamepad: () -> Bool
    }

    /// The key window, while one of this app's windows is key.
    private var focused: Window?
    /// The window that sent the last record, and what it sent.
    private var receiver: Window?
    private var sent: GamepadState?
    private var updatePending = false

    private init() {
        // GamepadHub reads the controllers for everyone.
        _ = GamepadHub.shared.addListener { [weak self] _, _ in self?.update() }
        _ = NotificationCenter.default.addObserver(forName: GamepadHub.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    /// `owner` became key with its display attached: it drives the gamepad now.
    func focus(_ owner: AnyObject, send: @escaping (GamepadState) -> Void, mappingTakesGamepad: @escaping () -> Bool) {
        focused = Window(id: ObjectIdentifier(owner), send: send, mappingTakesGamepad: mappingTakesGamepad)
        // Another app may have unplugged the gamepad meanwhile: say it all again.
        sent = nil
        update()
    }

    /// `owner` is no longer key: nothing stays held, but the gamepad stays
    /// plugged in, so a game does not pause for a lost controller on every ⌘Tab.
    func resign(_ owner: AnyObject) {
        guard focused?.id == ObjectIdentifier(owner) else { return }
        focused = nil
        if let receiver, receiver.id == ObjectIdentifier(owner), sent?.connected == true {
            send(GamepadState(pad: 0), to: receiver)
        }
    }

    /// `owner` closes or the app quits. It sends nothing: the guest unplugs
    /// the gamepad when the display of the window that drove it last closes
    /// (HostAgent), and leaves it to another app's window that took it over.
    func remove(_ owner: AnyObject) {
        if focused?.id == ObjectIdentifier(owner) { focused = nil }
        guard let receiver, receiver.id == ObjectIdentifier(owner) else { return }
        self.receiver = nil
        sent = nil
    }

    /// Something that decides who gets the gamepad changed (Game Mode, the
    /// profile), or the controller moved. One record covers all the elements
    /// one controller report changed (GameController calls back per element).
    func update() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    private func flush() {
        updatePending = false
        guard let focused else { return }
        guard !focused.mappingTakesGamepad(), let pad = GamepadHub.activePad() else {
            send(GamepadState(pad: 0, connected: false), to: focused)
            return
        }
        send(GamepadHub.reading(of: pad).state(), to: focused)
    }

    private func send(_ state: GamepadState, to window: Window) {
        guard receiver?.id != window.id || sent != state else { return }
        window.send(state)
        receiver = window
        sent = state
    }
}
