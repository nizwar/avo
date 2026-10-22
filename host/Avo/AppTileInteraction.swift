import AppKit
import AvoKit
import AvoWindowHost
import SwiftUI

// How every app in the Library answers the pointer (Home's cards and tiles,
// Games and Apps, search results, the sidebar's running apps):
//
// - a click opens the app, in its own window;
// - pressing and holding opens its page: the tile gives a little and a ring
//   of Avo green runs around it, and leaving the tile before it closes
//   cancels;
// - a right click (or Control-click) shows its menu in the haze (HazeMenu.swift
//   in the Window Host).
//
// With the keyboard (Full Keyboard Access), Return or Space opens it, ⌘I
// shows its page and Control-Return its menu; VoiceOver gets the same as
// actions.

/// An app's menu: what the system's context menu had, and the page's More menu.
@MainActor
enum AppMenu {
    static func entries(for app: AppRecord, model: ControlPanelModel, router: LibraryRouter) -> [HazeMenuEntry] {
        var entries: [HazeMenuEntry] = [
            .item(HazeMenuItem(title: String(localized: "Open"), symbol: "play.fill", shortcut: "↩") { model.open(app) }),
            .item(HazeMenuItem(title: model.isGame(app) ? String(localized: "Game Page") : String(localized: "App Page"),
                               symbol: "info.circle", shortcut: "⌘I") { router.open(app) }),
            .separator(),
            .item(HazeMenuItem(title: String(localized: "Force Stop"), symbol: "stop.circle",
                               isEnabled: model.activity[app.package] != nil) { model.forceStop(app) }),
        ]
        if let shim = app.shortcuts.shimPath {
            entries.append(.item(HazeMenuItem(title: String(localized: "Show in Finder"), symbol: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: shim)])
            }))
        }
        entries.append(.separator())
        entries.append(.item(HazeMenuItem(title: String(localized: "Clear Data…"), symbol: "eraser") {
            router.confirmation = AppConfirmation(app: app, kind: .clearData)
        }))
        // A system app (the Play Store, the Google app) cannot be uninstalled.
        if !app.systemApp {
            entries.append(.item(HazeMenuItem(title: String(localized: "Uninstall…"), symbol: "trash", role: .destructive) {
                router.confirmation = AppConfirmation(app: app, kind: .uninstall)
            }))
        }
        return entries
    }

    static func show(for app: AppRecord, model: ControlPanelModel, router: LibraryRouter, at point: NSPoint,
                     event: NSEvent? = nil, byKeyboard: Bool = false) {
        HazeMenuPresenter.shared.show(entries(for: app, model: model, router: router),
                                      header: HazeMenuHeader(title: app.displayName, icon: model.icons[app.package]),
                                      at: point, for: event, byKeyboard: byKeyboard)
    }

    /// A point in a window's SwiftUI space (top-left origin) on the screen.
    static func screenPoint(_ point: CGPoint, in window: NSWindow?) -> NSPoint? {
        guard let window, let content = window.contentView else { return nil }
        return window.convertPoint(toScreen: NSPoint(x: point.x, y: content.bounds.height - point.y))
    }
}

/// Right clicks and Control-clicks go to the app under the pointer: the
/// tile the pointer is over says so (one local event watch for all of them).
@MainActor
final class AppTileMenus {
    static let shared = AppTileMenus()

    private var hovered: (id: UUID, show: (NSPoint, NSEvent) -> Void)?
    private var monitor: Any?

    func hover(_ id: UUID, show: @escaping (NSPoint, NSEvent) -> Void) {
        hovered = (id, show)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            AppTileMenus.shared.click(event)
        }
    }

    func leave(_ id: UUID) {
        if hovered?.id == id { hovered = nil }
    }

    private func click(_ event: NSEvent) -> NSEvent? {
        guard event.type == .rightMouseDown || event.modifierFlags.contains(.control), let hovered,
              let window = event.window, !HazeMenuPresenter.shared.isMenu(window) else { return event }
        hovered.show(window.convertPoint(toScreen: event.locationInWindow), event)
        return nil
    }
}

/// Clear Data… or Uninstall… from an app's menu, waiting for its
/// confirmation (LibraryView).
struct AppConfirmation: Identifiable {
    enum Kind {
        case clearData, uninstall
    }

    let app: AppRecord
    let kind: Kind

    var id: String { "\(app.package) \(kind)" }
}

extension View {
    /// An app tile: click opens, press and hold opens the page, right click
    /// shows the menu (see the top of AppTileInteraction.swift).
    /// `cornerRadius`: the tile's, for its ring and focus. `pressScale`: how
    /// far it gives while pressed. `accessible`: the tile is one element
    /// for VoiceOver with the actions (false: it keeps its own elements).
    func appTileActions(_ app: AppRecord, cornerRadius: CGFloat, pressScale: CGFloat = Haze.Motion.cardPressScale,
                        accessible: Bool = true) -> some View {
        modifier(AppTileInteraction(app: app, cornerRadius: cornerRadius, pressScale: pressScale, accessible: accessible))
    }
}

/// Where a tile is in its window (not observed: moving costs no redraw).
private final class TileFrame {
    var frame: CGRect = .zero
}

private struct AppTileInteraction: ViewModifier {
    @Environment(ControlPanelModel.self) private var model
    @Environment(LibraryRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let app: AppRecord
    let cornerRadius: CGFloat
    let pressScale: CGFloat
    let accessible: Bool

    private enum Phase {
        case idle, pressing, cancelled, held
    }

    /// How long a press opens the page instead of the app.
    static let hold: Duration = .milliseconds(450)
    /// The ring shows once a press is longer than a click.
    static let ringDelay: Duration = .milliseconds(120)

    @State private var phase = Phase.idle
    @State private var progress: CGFloat = 0
    @State private var holding: Task<Void, Never>?
    @State private var tile = TileFrame()
    @State private var id = UUID()
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .scaleEffect(phase == .pressing && !reduceMotion ? pressScale : 1)
            .animation(Haze.Motion.press, value: phase == .pressing)
            .overlay {
                shape.inset(by: 1)
                    .trim(from: 0, to: progress)
                    .stroke(Haze.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .shadow(color: Haze.accent.opacity(0.7), radius: 6)
                    .opacity(progress > 0 ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .overlay {
                if focused {
                    shape.inset(by: -3).stroke(Haze.accent.opacity(0.85), lineWidth: 2).allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { tile.frame = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { pressed(at: $0.location) }
                .onEnded { released(at: $0.location) })
            .onHover { inside in
                if inside {
                    AppTileMenus.shared.hover(id) { point, event in showMenu(at: point, event: event) }
                } else {
                    AppTileMenus.shared.leave(id)
                }
            }
            .onDisappear {
                AppTileMenus.shared.leave(id)
                holding?.cancel()
            }
            .focusable(interactions: .activate)
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: .down) { key($0) }
            .modifier(TileAccessibility(enabled: accessible, pageName: model.isGame(app) ? Text("Game Page") : Text("App Page"),
                                        open: open, page: page, menu: { showMenuAtTile(byKeyboard: true) }))
    }

    // MARK: The pointer

    private func inside(_ location: CGPoint) -> Bool {
        CGRect(origin: .zero, size: tile.frame.size).insetBy(dx: -6, dy: -6).contains(location)
    }

    private func pressed(at location: CGPoint) {
        switch phase {
        case .idle:
            phase = .pressing
            holding?.cancel()
            holding = Task { @MainActor in
                try? await Task.sleep(for: Self.ringDelay)
                guard !Task.isCancelled, phase == .pressing else { return }
                withAnimation(.linear(duration: (Self.hold - Self.ringDelay) / .seconds(1))) { progress = 1 }
                try? await Task.sleep(for: Self.hold - Self.ringDelay)
                guard !Task.isCancelled, phase == .pressing else { return }
                phase = .held
                NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                page()
            }
        case .pressing where !inside(location):
            // Off the tile: neither opens.
            phase = .cancelled
            holding?.cancel()
            withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
        default:
            break
        }
    }

    private func released(at location: CGPoint) {
        holding?.cancel()
        if phase == .pressing, inside(location) { open() }
        phase = .idle
        withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
    }

    // MARK: Actions

    private func open() {
        model.open(app)
    }

    private func page() {
        router.open(app)
    }

    private func showMenu(at point: NSPoint, event: NSEvent?) {
        AppMenu.show(for: app, model: model, router: router, at: point, event: event)
    }

    /// From the keyboard or VoiceOver: under the tile's leading edge.
    private func showMenuAtTile(byKeyboard: Bool) {
        let frame = tile.frame
        let window = NSApp.keyWindow ?? NSApp.mainWindow
        guard let point = AppMenu.screenPoint(CGPoint(x: frame.minX + 12, y: min(frame.maxY, frame.minY + 44)), in: window) else { return }
        AppMenu.show(for: app, model: model, router: router, at: point, byKeyboard: byKeyboard)
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.isEmpty, press.key == .return || press.key == .space {
            open()
        } else if press.modifiers == .command, press.characters == "i" {
            page()
        } else if press.modifiers == .control, press.key == .return {
            showMenuAtTile(byKeyboard: true)
        } else {
            return .ignored
        }
        return .handled
    }
}

/// One element that opens the app, with the page and the menu as actions.
private struct TileAccessibility: ViewModifier {
    let enabled: Bool
    let pageName: Text
    let open: () -> Void
    let page: () -> Void
    let menu: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text("Opens the app. Press and hold for its page."))
                .accessibilityAction { open() }
                .accessibilityAction(named: pageName) { page() }
                .accessibilityAction(.showMenu) { menu() }
        } else {
            content
                .accessibilityAction(named: pageName) { page() }
                .accessibilityAction(.showMenu) { menu() }
        }
    }
}
