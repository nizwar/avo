import AppKit
import AvoDaemonCore
import AvoHazeUI
import AvoKit
import AvoWindowHost
import SwiftUI

/// Menu Bar Item (spec: NSStatusItem with VM status, start/stop and a
/// shortcut to the Control Panel). A click opens a small panel in the
/// Library's look (MenuBarPanel.swift): Android's state, CPU and memory,
/// the running and recent apps, Start, Pause, Resume and Stop. A right
/// click (or Control-click) opens the menu, with every app, in the haze too
/// (HazeMenu.swift in AvoHazeUI).
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate, NSPopoverDelegate {
    private let core: DaemonCore
    private let avoApp: URL
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let popover = NSPopover()
    private let model = MenuBarModel()
    private var refreshing: Task<Void, Never>?
    private var status = VMStatus.stopped
    private var apps: [AppRecord] = []
    /// Google apps are changing Android: Stop and Quit ask first.
    private var googleAppsWork: GoogleAppsWork?
    /// Avo was updated while Android ran: the daemon restarts on the new
    /// build once Android stops (AppUpdateWatcher), which the menu offers.
    var updatePending: @MainActor () -> Bool = { false }
    /// `force`: Stop Anyway, while Google apps change Android.
    var restartForUpdate: @MainActor (_ force: Bool) async throws -> Void = { _ in }

    /// Avo's appearance (Settings › General › Appearance) for the panel and
    /// the menu; nil, as the Mac.
    var appearance: NSAppearance? {
        didSet { popover.appearance = panelAppearance }
    }

    /// Not the menu bar's (the item's button wears that): Avo's, else the Mac's.
    private var panelAppearance: NSAppearance { appearance ?? NSApp.effectiveAppearance }

    /// The item is off the menu bar (`remove`).
    private var removed = false

    /// How long MenuBarAgent is given to take the item away before the
    /// process ends (`remove` reaches it asynchronously), in milliseconds.
    static let removalGraceMilliseconds = 300

    init(core: DaemonCore, avoApp: URL) {
        self.core = core
        self.avoApp = avoApp
        super.init()
        let image = NSImage(named: "MenuBarIcon")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Avo"
        item.button?.target = self
        item.button?.action = #selector(clicked(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.delegate = self
        // Its items say themselves whether they can be chosen (Start while
        // Android starts, Resume while it pauses): validating would enable
        // every item whose target answers its action.
        menu.autoenablesItems = false
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let panel = NSHostingController(rootView: MenuBarPanel(model: model, actions: panelActions))
        // The popover follows the panel's height as its lists fill in after
        // it opens; with a fixed size the taller panel ran off the top of
        // the screen, under the menu bar.
        panel.sizingOptions = .preferredContentSize
        popover.contentViewController = panel
        // Not core.vm.statusUpdates: that stream has a single reader, the core.
        Task { [weak self] in
            for await status in await core.statusChanges() { self?.update(status) }
        }
        Task { [weak self] in
            for await work in await core.googleAppsBusyChanges() {
                self?.googleAppsWork = work
                self?.model.googleAppsWork = work
            }
        }
    }

    private func update(_ status: VMStatus) {
        self.status = status
        model.status = status
        // Dim the icon while Android is not running (paused included).
        item.button?.appearsDisabled = status.state != .running
        item.button?.toolTip = status.isPaused ? String(localized: "Avo · Android is paused") : "Avo"
    }

    /// Takes the item off the menu bar with nothing of it left open: the
    /// panel, the menu and the item's highlight. Every way the daemon ends
    /// goes through here first (Avo #11: after Avo quit, the menu bar stayed
    /// over other apps' full screen until MenuBarAgent was restarted, and
    /// the item, gone with its process, perhaps lit or with its menu open,
    /// is what MenuBarAgent holds of Avo).
    func remove() {
        guard !removed else { return }
        removed = true
        popover.close()
        HazeMenuPresenter.shared.close(animated: false)
        item.button?.highlight(false)
        NSStatusBar.system.removeStatusItem(item)
    }

    // MARK: Click: the panel; right click: the menu

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            popover.performClose(nil)
            // Under the item, which stays lit meanwhile like any menu bar
            // menu's; the menu takes the keyboard.
            NSApp.activate()
            sender.highlight(true)
            HazeMenuPresenter.shared.popUp(menu, below: sender, appearance: panelAppearance) { sender.highlight(false) }
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            Task { await model.refresh(from: core) }
            NSApp.activate()
            // The Mac's look as it is now, while Avo's is System.
            popover.appearance = panelAppearance
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        }
    }

    func popoverDidShow(_ notification: Notification) {
        refreshing?.cancel()
        refreshing = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                await model.refresh(from: core)
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        refreshing?.cancel()
        refreshing = nil
    }

    private var panelActions: MenuBarActions {
        MenuBarActions(
            start: { [weak self] in self?.startVM() },
            pause: { [weak self] in self?.pauseVM() },
            resume: { [weak self] in self?.resumeVM() },
            restart: { [weak self] in self?.restartVM() },
            stop: { [weak self] in self?.stopVM() },
            open: { [weak self] app in
                self?.popover.performClose(nil)
                guard let shim = app.shortcuts.shimPath else { return }
                NSWorkspace.shared.openApplication(at: URL(filePath: shim), configuration: NSWorkspace.OpenConfiguration())
            },
            openAvo: { [weak self] in
                self?.popover.performClose(nil)
                self?.openControlPanel()
            },
            quit: { [weak self] in self?.quit() })
    }

    // MARK: The menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let state = NSMenuItem(title: Self.title(for: status), action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        if let work = googleAppsWork {
            let title = work == .removing ? String(localized: "Removing Google apps…") : String(localized: "Installing Google apps…")
            let busy = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        }
        switch status.state {
        case .running:
            if core.vm.canPause {
                menu.addItem(withTitle: String(localized: "Pause Android"), action: #selector(pauseVM), keyEquivalent: "").symbol("pause.circle")
                    .target = self
            }
            menu.addItem(withTitle: String(localized: "Restart Android"), action: #selector(restartVM), keyEquivalent: "")
                .symbol("arrow.clockwise.circle").target = self
            menu.addItem(withTitle: String(localized: "Stop Android"), action: #selector(stopVM), keyEquivalent: "").symbol("stop.circle").target = self
        case .starting:
            // A start can take minutes: it can be stopped too.
            menu.addItem(withTitle: String(localized: "Stop Android"), action: #selector(stopVM), keyEquivalent: "").symbol("stop.circle").target = self
        case .suspended, .suspending:
            let resume = menu.addItem(withTitle: String(localized: "Resume Android"), action: #selector(resumeVM), keyEquivalent: "")
            resume.target = self
            resume.symbol("play.circle")
            resume.isEnabled = status.state == .suspended
            menu.addItem(withTitle: String(localized: "Stop Android"), action: #selector(stopVM), keyEquivalent: "").symbol("stop.circle").target = self
        default:
            let start = menu.addItem(withTitle: String(localized: "Start Android"), action: #selector(startVM), keyEquivalent: "")
            start.target = self
            start.symbol("play.circle")
            // The installer starts Android itself (and may be repairing it);
            // without an Android image there is nothing to start (as in the panel).
            start.isEnabled = ![.stopping, .notInstalled].contains(status.state) && googleAppsWork == nil
        }
        menu.addItem(.separator())

        if !apps.isEmpty {
            let appsItem = NSMenuItem(title: String(localized: "Apps"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            for app in apps.prefix(30) where app.shortcuts.shimPath != nil {
                let entry = submenu.addItem(withTitle: app.displayName, action: #selector(openApp(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = app.shortcuts.shimPath
                if let shim = app.shortcuts.shimPath {
                    let icon = NSWorkspace.shared.icon(forFile: shim)
                    icon.size = NSSize(width: 16, height: 16)
                    entry.image = icon
                }
            }
            appsItem.submenu = submenu
            appsItem.symbol("square.grid.2x2")
            menu.addItem(appsItem)
        }
        menu.addItem(withTitle: String(localized: "Open Avo"), action: #selector(openControlPanel), keyEquivalent: ",")
            .symbol("slider.horizontal.3").target = self
        // Sparkle runs in the Control Panel (Avo.app's AppUpdater): it opens and checks.
        menu.addItem(withTitle: String(localized: "Check for Updates…"), action: #selector(checkForUpdates), keyEquivalent: "")
            .symbol("arrow.down.circle").target = self
        if updatePending() {
            menu.addItem(withTitle: String(localized: "Restart Android to Finish Updating Avo"), action: #selector(restartForUpdateNow),
                         keyEquivalent: "").symbol("arrow.clockwise.circle").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Avo"), action: #selector(quit), keyEquivalent: "q").symbol("power").target = self

        Task { [weak self] in
            guard let self else { return }
            self.apps = await core.apps()
        }
    }

    private static func title(for status: VMStatus) -> String {
        // Not responding, over the windows it has open.
        if status.isNotResponding { return MenuBarPanel.title(for: status) }
        return switch status.state {
        case .running where status.openDisplays > 0: String(localized: "Android is running · \(status.openDisplays) open windows")
        case .failed: status.detail.map { String(localized: "Android stopped: \($0)") } ?? String(localized: "Android stopped with an error")
        default: MenuBarPanel.title(for: status)
        }
    }

    // MARK: Actions

    @objc private func startVM() {
        Task {
            do {
                try await core.startVMFromMenuBar()
            } catch {
                show(error)
            }
        }
    }

    @objc private func pauseVM() {
        Task {
            do {
                try await core.pauseFromMenuBar()
            } catch {
                show(error)
            }
        }
    }

    @objc private func resumeVM() {
        Task {
            do {
                try await core.resumeFromMenuBar()
            } catch {
                show(error)
            }
        }
    }

    @objc private func restartVM() {
        Task {
            do {
                try await core.restartVMFromMenuBar()
            } catch {
                // Google apps change Android: it asks first, as Stop does.
                guard googleAppsWork != nil else { return show(error) }
                guard confirmForce(error, action: String(localized: "Restart Anyway")) else { return }
                do {
                    try await core.restartVMFromMenuBar(force: true)
                } catch {
                    show(error)
                }
            }
        }
    }

    @objc private func stopVM() {
        Task {
            do {
                try await core.stopVMFromMenuBar()
            } catch {
                guard confirmForce(error, action: String(localized: "Stop Anyway")) else { return }
                try? await core.stopVMFromMenuBar(force: true)
            }
        }
    }

    @objc private func openApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openControlPanel() {
        NSWorkspace.shared.openApplication(at: avoApp, configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func checkForUpdates() {
        NSWorkspace.shared.open([ControlPanelLink.url(pane: ControlPanelLink.checkForUpdates)], withApplicationAt: avoApp,
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func restartForUpdateNow() {
        Task {
            do {
                try await restartForUpdate(false)
            } catch {
                guard confirmForce(error, action: String(localized: "Stop Anyway")) else { return }
                try? await restartForUpdate(true)
            }
        }
    }

    @objc private func quit() {
        Task {
            do {
                try await core.quitFromMenuBar()
            } catch {
                guard confirmForce(error, action: String(localized: "Quit Anyway")) else { return }
                try? await core.quitFromMenuBar(force: true)
            }
            // Avo quits as a whole: an open Control Panel, reconnecting,
            // would have launchd start the daemon (and this item) again.
            let controlPanel = Bundle(url: avoApp)?.bundleIdentifier ?? AvoIdentifiers.app
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: controlPanel) { app.terminate() }
            remove()
            try? await Task.sleep(for: .milliseconds(Self.removalGraceMilliseconds))
            exit(0)
        }
    }

    /// Says why an action from the panel or the menu failed, in an alert as
    /// Stop's question is shown; nothing of a start that a stop called off
    /// (the user's own Stop, mostly), which the status says.
    private func show(_ error: any Error) {
        guard !(error is CancellationError), error as? AvoError != .startCalledOff else { return }
        popover.performClose(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        NSApp.activate()
        alert.runModal()
    }

    /// Google apps are changing Android: stopping it now can leave it unable
    /// to start until Avo repairs it at the next start. True to go ahead.
    private func confirmForce(_ error: any Error, action: String) -> Bool {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = error.localizedDescription
        if googleAppsWork == .removing {
            alert.informativeText = String(localized: "Stopping Android now interrupts the removal. Avo finishes removing Google apps the next time Android starts.")
            alert.addButton(withTitle: String(localized: "Keep Removing"))
        } else {
            // True before and after the commit: only one that began leaves
            // something for the next start to finish or undo.
            alert.informativeText = String(localized: "Stopping Android now interrupts the install. If Google apps were already being copied into Android, Avo finishes or undoes the install the next time Android starts; otherwise, install them again.")
            alert.addButton(withTitle: String(localized: "Keep Installing"))
        }
        alert.addButton(withTitle: action)
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
