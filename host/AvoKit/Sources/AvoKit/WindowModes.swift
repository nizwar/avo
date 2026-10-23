import CoreGraphics
import Foundation

/// How an app window looks: the Control Panel's for every app (Settings ›
/// Graphics › App windows › App bar style), or the app's own
/// (`WindowModeSettings.appBarStyle`, from its window's Device menu, View
/// menu or Quick Settings).
public enum AppBarStyle: String, Codable, CaseIterable, Sendable {
    /// A Mac window, its title bar always shown.
    case standard
    /// Screen Only: the app's screen alone with a phone's rounded corners;
    /// the title bar grows out above it while the pointer leaves the screen
    /// through its top, as in iPhone Mirroring.
    case phone
}

/// Picture in Picture for an app window: the app in a small borderless
/// window over every other, in a corner of the screen, with the picture's
/// shape. The Window Host moves the window's content into it; this is where
/// it goes and how big it is.
public enum PictureInPicture {
    public enum Corner: String, Sendable, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Between the mini window and the edges of the screen's visible area.
    public static let margin: CGFloat = 16
    /// Its shorter side is at least this long…
    public static let minimumShortSide: CGFloat = 120
    /// …and its longer side at most this share of the visible area along it.
    public static let maximumShare: CGFloat = 0.5
    /// Without a size of the user's: about this share of the visible area.
    static let defaultArea: CGFloat = 0.06

    /// The mini window's size for a picture `aspect` wide per unit of height:
    /// `longSide` (its longer side as the user left it) or the default,
    /// within the limits above on this screen.
    public static func size(aspect: CGFloat, longSide: CGFloat?, visible: CGRect) -> CGSize {
        let aspect = aspect.isFinite && aspect > 0 ? aspect : 1
        let landscape = aspect >= 1
        let long = longSide ?? (visible.width * visible.height * defaultArea * (landscape ? aspect : 1 / aspect)).squareRoot()
        // Long and short side of the picture, then the limits on each.
        let ratio = landscape ? aspect : 1 / aspect
        let room = landscape ? visible.width : visible.height
        let maximum = max(min(room * maximumShare, (landscape ? visible.height : visible.width) * maximumShare * ratio),
                          minimumShortSide * ratio)
        let clamped = min(max(long, minimumShortSide * ratio), maximum)
        let short = clamped / ratio
        return landscape ? CGSize(width: clamped.rounded(), height: short.rounded())
                         : CGSize(width: short.rounded(), height: clamped.rounded())
    }

    /// The frame of that size in `corner` of the visible area.
    public static func frame(size: CGSize, corner: Corner, visible: CGRect) -> CGRect {
        let left = corner == .topLeft || corner == .bottomLeft
        let top = corner == .topLeft || corner == .topRight
        let x = left ? visible.minX + margin : visible.maxX - margin - size.width
        let y = top ? visible.maxY - margin - size.height : visible.minY + margin
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// The corner nearest to where the user dragged the mini window (by its
    /// centre, in the screen's bottom-up coordinates).
    public static func nearestCorner(to frame: CGRect, in visible: CGRect) -> Corner {
        let left = frame.midX < visible.midX
        let top = frame.midY >= visible.midY
        switch (top, left) {
        case (true, true): return .topLeft
        case (true, false): return .topRight
        case (false, true): return .bottomLeft
        case (false, false): return .bottomRight
        }
    }
}

/// Keep on Top, where Picture in Picture goes and the app bar style, per
/// app: kept in its App Shim's own defaults. Picture in Picture itself is not remembered: a new
/// window opens as a window.
public struct WindowModeSettings {
    public static let keepOnTopKey = "AvoKeepOnTop"
    public static let appBarStyleKey = "AvoAppBarStyle"
    public static let cornerKey = "AvoPictureInPictureCorner"
    public static let longSideKey = "AvoPictureInPictureSize"

    public let store: UserDefaults

    public init(store: UserDefaults) {
        self.store = store
    }

    /// The app's windows float over other apps' windows.
    public var keepOnTop: Bool {
        get { store.bool(forKey: Self.keepOnTopKey) }
        nonmutating set {
            if newValue { store.set(true, forKey: Self.keepOnTopKey) } else { store.removeObject(forKey: Self.keepOnTopKey) }
        }
    }

    /// The app's own app bar style; nil follows the Control Panel's
    /// (`VMConfig.appBarStyle`).
    public var appBarStyle: AppBarStyle? {
        get { store.string(forKey: Self.appBarStyleKey).flatMap(AppBarStyle.init(rawValue:)) }
        nonmutating set {
            if let newValue { store.set(newValue.rawValue, forKey: Self.appBarStyleKey) } else { store.removeObject(forKey: Self.appBarStyleKey) }
        }
    }

    /// Where the mini window was left (bottom right at first).
    public var corner: PictureInPicture.Corner {
        get { store.string(forKey: Self.cornerKey).flatMap(PictureInPicture.Corner.init(rawValue:)) ?? .bottomRight }
        nonmutating set { store.set(newValue.rawValue, forKey: Self.cornerKey) }
    }

    /// Its longer side as the user resized it, in points; nil for the default.
    public var longSide: CGFloat? {
        get {
            guard let side = store.object(forKey: Self.longSideKey) as? Double, side > 0 else { return nil }
            return CGFloat(side)
        }
        nonmutating set {
            if let newValue { store.set(Double(newValue), forKey: Self.longSideKey) } else { store.removeObject(forKey: Self.longSideKey) }
        }
    }
}

/// Whether closing a game's window asks first (Settings › Graphics › App
/// windows › Ask before quitting a game, and the question's Don't Ask
/// Again), for every app: the red light and Picture in Picture's ✕ end the
/// game in Android, and one wrong click must not end a match. Kept in the
/// Window Host's defaults, which every App Shim reads.
public struct QuitSettings {
    public static let askKey = "AvoAskBeforeQuittingGames"

    public let store: UserDefaults

    public init(store: UserDefaults) {
        self.store = store
    }

    /// On unless turned off.
    public var asksBeforeQuittingGames: Bool {
        get { store.object(forKey: Self.askKey) as? Bool ?? true }
        nonmutating set {
            if newValue { store.removeObject(forKey: Self.askKey) } else { store.set(false, forKey: Self.askKey) }
        }
    }
}
