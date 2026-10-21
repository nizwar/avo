import AppKit
import AvoKeymap

/// The key mapping editor over a game (spec §5: "Tekan Cmd+Shift+K di
/// jendela game untuk membuka editor overlay transparan"). It is a view on
/// top of the game inside the game's own window, not a window of its own,
/// so it always has the window's size and place, and other apps' windows
/// cover it like they cover the game. The editing itself is KeymapEditorView.
@MainActor
final class KeymapOverlay {
    private let editor: KeymapEditorView
    private weak var window: NSWindow?
    private weak var focusBefore: NSResponder?
    var onClose: (() -> Void)?

    var isEditing: Bool { editor.superview != nil }

    init(window: NSWindow, view: DisplayView, package: String, profile: KeymapProfile?,
         onSave: @escaping (KeymapProfile) -> String?) {
        editor = KeymapEditorView(displayRect: { [weak view] in view?.displayRect ?? .zero },
                                  profile: profile ?? KeymapProfile(package: package, name: String(localized: "My layout", bundle: .windowHost), controls: []),
                                  onSave: onSave)
        self.window = window
        editor.onClose = { [weak self] in self?.close() }
    }

    func show() {
        guard let window, let content = window.contentView, !isEditing else { return }
        editor.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(editor, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            editor.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            editor.topAnchor.constraint(equalTo: content.topAnchor),
            editor.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        focusBefore = window.firstResponder
        window.makeFirstResponder(editor)
    }

    func close() {
        guard isEditing else { return }
        editor.removeFromSuperview()
        if let window, let focusBefore { window.makeFirstResponder(focusBefore) }
        onClose?()
    }

    /// Key presses routed here while the editor is open.
    func assign(_ trigger: Trigger, down: Bool) -> Bool {
        if down { editor.assign(trigger) }
        return true
    }
}
