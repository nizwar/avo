import AppKit
import AvoKeymap
import AvoKit

// What a window gives its key mapping (KeymapController, the editor, the
// hints): the view the game is drawn in, and where the mapping keeps its
// profiles and Game Mode. Avo's app windows and Avo Hub's mirror windows
// run the same key mapping over these; the rest is the module's own.

/// The view the game is drawn in, which the key mapping sits on: Avo's
/// DisplayView, Avo Hub's MirrorView. The editor covers its superview.
@MainActor
public protocol KeymapDisplay: NSView {
    /// Where the picture is drawn, in view points measured from the view's
    /// bottom left (y up), whether or not the view is flipped.
    var displayRect: CGRect { get }
    /// Android's display, in pixels: what touches are measured in.
    var displaySize: CGSize { get }
}

/// Where a window's key mapping keeps its profiles and Game Mode.
public struct KeymapStore {
    /// The user's profile for the app: saving writes it.
    public var profileURL: URL
    /// The community profiles shipped with the app.
    public var bundledDirectory: URL?
    /// The profile to use when the window opens: the user's, else the
    /// community one (KeymapProfile.usable).
    public var usable: () -> (profile: KeymapProfile, url: URL)?
    /// Whether Game Mode was on last time.
    public var gameMode: () -> Bool
    public var setGameMode: (Bool) -> Void

    public init(profileURL: URL, bundledDirectory: URL?, usable: @escaping () -> (profile: KeymapProfile, url: URL)?,
                gameMode: @escaping () -> Bool, setGameMode: @escaping (Bool) -> Void) {
        self.profileURL = profileURL
        self.bundledDirectory = bundledDirectory
        self.usable = usable
        self.gameMode = gameMode
        self.setGameMode = setGameMode
    }

    /// Avo's: the user's profiles in ~/Library/Application Support/Avo/keymaps,
    /// the community ones in Avo.app, and Game Mode in the App Shim's
    /// defaults, so remembered per app (one app per shim).
    public static func avo(package: String, hostApplication: URL?) -> KeymapStore {
        let bundled = bundledDirectory(hostApplication: hostApplication)
        return KeymapStore(profileURL: AvoPaths().keymap(for: package), bundledDirectory: bundled,
                           usable: { KeymapProfile.usable(for: package, bundledDirectory: bundled) },
                           gameMode: { UserDefaults.standard.bool(forKey: "AvoGameMode") },
                           setGameMode: { UserDefaults.standard.set($0, forKey: "AvoGameMode") })
    }

    /// Where Avo.app keeps the community profiles.
    public static func bundledDirectory(hostApplication: URL?) -> URL? {
        hostApplication?.appending(path: "Contents/Resources/profiles/keymaps")
    }
}
