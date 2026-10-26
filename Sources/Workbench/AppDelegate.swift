import AppKit
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var store: Store!
    private var runtime: Runtime!
    private var workspace: WorkspaceController!
    private var control: ControlServer?
    private var settings: SettingsWindowController?
    private var pendingRestore: (backup: Backup, rollback: URL)?   // Settings > Backup import: installed at quit (rollback = the setup saved just before), then we relaunch into it
    private var relaunchAfterQuit = false   // Restart Workbench: sessions stay alive, we reopen after exit
    private let themeMenu = NSMenu(title: "Theme")
    private var reserved: [String: NSMenuItem] = [:]   // "key|mods" → item; looked up on every ⌘/⌃ keyDown in a terminal

    func applicationDidFinishLaunching(_ notification: Notification) {
        Agents.discoverLaunchers()
        store = Store()
        store.onChange = { [unowned self] in BackupSync.shared.scheduleSync(store) }
        runtime = Runtime(overrides: WorkspaceController.overrides(Theme.named(store.layout.theme), jira: store.layout.jira))
        NSApp.mainMenu = buildMenu()
        rebuildThemeMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(rebuildThemeMenu), name: .themeChanged, object: nil)
        workspace = WorkspaceController(store: store, runtime: runtime)
        workspace.showWindow(nil)

        SurfaceView.isReservedShortcut = { [unowned self] event in performReserved(event) }

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let server = ControlServer(path: Store.directory.appendingPathComponent("pane.sock").path) { [unowned self] msg, reply in
            workspace.handleControl(msg, reply: reply)
        }
        server.start()
        control = server

        NSApp.activate()

        var live = Set<PaneID>()
        for p in store.layout.projects { for t in p.tabs { for leaf in t.root.leaves { if case .terminal = leaf.kind { live.insert(leaf.id) } } } }
        DispatchQueue.global(qos: .utility).async { [live] in Session.endOrphans(keeping: live) }

        if let data = readFile(Store.restoreError, cap: 1 << 16) {
            try? FileManager.default.removeItem(at: Store.restoreError)
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The restore didn't finish"
            alert.informativeText = String(decoding: data, as: UTF8.self)
            alert.runModal()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runtime?.setFocus(true)
        if let store { BackupSync.shared.scheduleSync(store) }   // themes and the Ghostty config change outside the layout; an unchanged file makes no commit
    }
    func applicationDidResignActive(_ notification: Notification) { runtime?.setFocus(false) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard pendingRestore == nil, !Session.keepOnClose, workspace.needsConfirmQuit else { return .terminateNow }   // an import already confirmed
        let alert = NSAlert()
        alert.messageText = "Quit Workbench?"
        alert.informativeText = "Running processes will be closed. Claude and Codex sessions resume on next launch."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // ponytail: on quit we only retire surfaces (SIGHUP children) and flush; process exit reclaims the rest,
    // so ghostty_app_free is skipped to avoid racing the background surface frees.
    func applicationWillTerminate(_ notification: Notification) {
        control?.stop()
        workspace.terminateAll(keeping: Set(pendingRestore?.0.layout.projects.flatMap { $0.tabs.flatMap { $0.root.leaves.map(\.id) } } ?? []))
        Session.waitForEnds(timeout: 5)   // hosts give a shell up to 3 s to exit; under Restart nothing is ending
        if let (backup, rollback) = pendingRestore {
            do { try backup.install(backupRemote: store.layout.backupRemote) } catch {
                let previous = readFile(rollback, cap: Backup.maxSize).flatMap { try? Backup.decode($0) }
                let undone = previous.map { (try? $0.install(backupRemote: store.layout.backupRemote)) != nil } ?? false
                let note = (error as? BackupError)?.message ?? error.localizedDescription
                try? Data((note + (undone ? " Workbench put back the setup you had before." : " Your previous setup couldn't be put back; it is saved in \(rollback.path).")).utf8)
                    .write(to: Store.restoreError, options: .atomic)
            }
            relaunch()
        } else {
            BackupSync.shared.flush(store)   // a change still waiting for its debounce
            if relaunchAfterQuit { relaunch() }
        }
    }

    /// Replaces the whole setup with `backup`: quit (surfaces retire, the old layout saves), install, reopen; if installing fails, the saved setup is put back and the error shown after relaunch.
    func restore(_ backup: Backup, rollback: URL) {
        pendingRestore = (backup, rollback)
        NSApp.terminate(nil)
    }

    @objc private func restartWorkbench(_ sender: Any?) {
        Session.keepOnClose = true
        relaunchAfterQuit = true
        NSApp.terminate(nil)
    }

    /// Reopens this app once this process has exited (the instance lock refuses a second copy while we live).
    private func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        var open = ["open", "-n", "\"$2\""]
        if let dir = ProcessInfo.processInfo.environment["PANE_STATE_DIR"] { open += ["--env", "PANE_STATE_DIR=\"$3\""] }
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.1; done; " + open.joined(separator: " "), "sh",
                       String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
                       ProcessInfo.processInfo.environment["PANE_STATE_DIR"] ?? ""]
        try? p.run()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // MARK: - Notifications

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = (response.notification.request.content.userInfo["pane"] as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            MainActor.assumeIsolated { if let id { self.workspace.focusPane(id) } }
        }
        completionHandler()
    }

    // MARK: - Menu

    private func performReserved(_ event: NSEvent) -> Bool {
        guard let chars = event.characters(byApplyingModifiers: [])?.lowercased() else { return false }
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard let match = reserved["\(chars)|\(mods.rawValue)"] else { return false }
        NSApp.sendAction(match.action!, to: match.target, from: match)
        return true
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command],
                      tag: Int = 0, reserved isReserved: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = mods
        item.tag = tag
        if isReserved, !key.isEmpty, reserved["\(key.lowercased())|\(mods.rawValue)"] == nil {
            reserved["\(key.lowercased())|\(mods.rawValue)"] = item
        }
        return item
    }

    /// Alternate shortcut: stays in the reserved set (so it works from a terminal) but not shown in the menu.
    private func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }

    private func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let m = NSMenu(title: title)
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    @objc private func openSettings(_ sender: Any?) {
        if settings == nil { settings = SettingsWindowController(workspace: workspace) }
        settings?.showWindow(nil)
        settings?.window?.makeKeyAndOrderFront(nil)
    }

    /// Dark / Light, then the custom themes; the current one checked.
    @objc private func rebuildThemeMenu() {
        themeMenu.removeAllItems()
        let current = store.layout.theme
        let all = Theme.all()
        for (i, group) in [all.filter(\.isSystem), all.filter { !$0.isSystem }].enumerated() where !group.isEmpty {
            if i > 0 { themeMenu.addItem(.separator()) }
            for theme in group {
                let t = NSMenuItem(title: theme.name, action: #selector(WorkspaceController.selectTheme(_:)), keyEquivalent: "")
                t.representedObject = theme.id
                t.state = theme.id == current ? .on : .off
                themeMenu.addItem(t)
            }
        }
    }

    private func arrow(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }

    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let w = WorkspaceController.self
        main.addItem(menu("Workbench", [
            NSMenuItem(title: "About Workbench", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""),
            .separator(),
            item("Settings…", #selector(openSettings(_:)), ","),
            .separator(),
            item("Hide Workbench", #selector(NSApplication.hide(_:)), "h"),
            item("Restart Workbench", #selector(restartWorkbench(_:)), "", reserved: false),
            item("Quit Workbench", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(menu("File", [
            item("New Tab", #selector(w.newTab(_:)), "t"),
            item("New Scratch Terminal", #selector(w.newScratchTerminal(_:)), "n", [.command, .shift]),
            item("Split Right", #selector(w.splitRight(_:)), "d"),
            item("Split Down", #selector(w.splitDown(_:)), "d", [.command, .shift]),
            .separator(),
            item("Add Project…", #selector(w.addProject(_:)), "o", [.command, .shift]),
            item("Open File…", #selector(w.openFileDialog(_:)), "o", [.command, .option]),
            .separator(),
            item("Close Pane", #selector(w.closePane(_:)), "w"),
            item("Close Tab", #selector(w.closeTab(_:)), "w", [.command, .shift]),
        ]))
        main.addItem(menu("Edit", [
            item("Undo", Selector(("undo:")), "z", reserved: false),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], reserved: false),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", reserved: false),
            item("Copy", #selector(SurfaceView.copy(_:)), "c", reserved: false),
            item("Paste", #selector(SurfaceView.paste(_:)), "v"),
            item("Select All", #selector(SurfaceView.selectAll(_:)), "a", reserved: false),
            .separator(),
            item("Find…", #selector(w.find(_:)), "f"),
            item("Find Next", #selector(w.findNext(_:)), "g"),
            item("Find Previous", #selector(w.findPrevious(_:)), "g", [.command, .shift]),
            item("Clear", #selector(w.clearScreen(_:)), "k"),
        ]))
        main.addItem(menu("View", [
            item("Toggle Sidebar", #selector(w.toggleProjectSidebar(_:)), "b"),
            item("Toggle TODO & Files", #selector(w.toggleInspectorPanel(_:)), "b", [.command, .option]),
            item("Equalize Splits", #selector(w.equalizeSplits(_:)), "0", [.command, .shift]),
            .separator(),
            item("Bigger", #selector(w.increaseFontSize(_:)), "="),
            item("Smaller", #selector(w.decreaseFontSize(_:)), "-"),
            item("Actual Size", #selector(w.resetFontSize(_:)), "0"),
            .separator(),
            { let t = NSMenuItem(title: "Theme", action: nil, keyEquivalent: ""); t.submenu = themeMenu; return t }(),
        ]))
        // Static titles (no workspace-change hook); items past the workspace count are no-ops.
        var projectItems: [NSMenuItem] = (1...9).map { item("Workspace \($0)", #selector(w.selectWorkspaceByTag(_:)), "\($0)", [.control], tag: $0) }
        projectItems += [
            item("Previous Workspace", #selector(w.previousWorkspace(_:)), arrow(NSUpArrowFunctionKey), [.command, .control]),
            item("Next Workspace", #selector(w.nextWorkspace(_:)), arrow(NSDownArrowFunctionKey), [.command, .control]),
            .separator(),
        ]
        projectItems += (1...9).map { item("Project \($0)", #selector(w.selectProjectByTag(_:)), "\($0)", tag: $0) }
        projectItems += [
            .separator(),
            item("Previous Project", #selector(w.previousProject(_:)), arrow(NSUpArrowFunctionKey), [.command, .option]),
            item("Next Project", #selector(w.nextProject(_:)), arrow(NSDownArrowFunctionKey), [.command, .option]),
        ]
        main.addItem(menu("Go", [item("Back", #selector(w.goBack(_:)), arrow(NSLeftArrowFunctionKey), [.command, .control]), item("Forward", #selector(w.goForward(_:)), arrow(NSRightArrowFunctionKey), [.command, .control]), .separator()] + projectItems + [
            .separator(),
            item("Previous Tab", #selector(w.previousTab(_:)), "[", [.command, .shift]),
            item("Next Tab", #selector(w.nextTab(_:)), "]", [.command, .shift]),
            hidden(item("Previous Tab", #selector(w.previousTab(_:)), arrow(NSLeftArrowFunctionKey), [.command, .option])),
            hidden(item("Next Tab", #selector(w.nextTab(_:)), arrow(NSRightArrowFunctionKey), [.command, .option])),
            .separator(),
            item("Previous Pane", #selector(w.focusPreviousPane(_:)), "["),
            item("Next Pane", #selector(w.focusNextPane(_:)), "]"),
            item("Focus Left", #selector(w.focusLeft(_:)), "h", [.command, .option]),
            item("Focus Down", #selector(w.focusDown(_:)), "j", [.command, .option]),
            item("Focus Up", #selector(w.focusUp(_:)), "k", [.command, .option]),
            item("Focus Right", #selector(w.focusRight(_:)), "l", [.command, .option]),
        ]))
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }
}

private extension Store {
    /// Why the last restore failed; shown (then deleted) at the next launch.
    static var restoreError: URL { directory.appendingPathComponent("restore-error.txt") }
}
