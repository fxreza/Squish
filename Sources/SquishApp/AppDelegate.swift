import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var mainWindowController: MainWindowController?
    private var preferencesWindowController: PreferencesWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        Preferences.shared.applyAppearance()
        buildMainMenu()
        NSApp.servicesProvider = self
        // Re-register so renamed entries appear immediately after an upgrade
        // rather than at the next login.
        NSUpdateDynamicServices()

        // Silent unless something newer exists, and throttled to once a day, so it
        // can never interrupt someone who only wanted to compress an image.
        UpdateChecker.shared.checkInBackground()

        // Do NOT unconditionally build a controller here. On a cold launch that opens
        // files - dragging onto the Dock icon while Squish is not running, or "Open
        // With" - `application(_:open:)` fires BEFORE this method. It will already
        // have created the controller and added those files, and replacing it here
        // would silently discard them.
        ensureMainWindowVisible()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureMainWindowVisible()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.cancelPendingWork()
        // Every preview ever computed lives in one scratch directory. Take it with us.
        let cache = PreviewCache.shared
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await cache.purge()
            semaphore.signal()
        }
        // Bounded: a slow disk must not hang the quit, and the next launch sweeps
        // any directory a previous run failed to remove anyway.
        _ = semaphore.wait(timeout: .now() + 2)
    }

    // MARK: - Dock icon / Open With drop target

    /// Files or folders dropped on the Dock icon, or opened via "Open With", land
    /// here. They are *added to the list*, like every other route in: nothing is
    /// written until Compress is pressed.
    func application(_ application: NSApplication, open urls: [URL]) {
        ensureMainWindowVisible()
        mainWindowController?.add(urls: urls)
    }

    private func ensureMainWindowVisible() {
        if mainWindowController == nil {
            mainWindowController = MainWindowController()
        }
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private var mainWindow: MainWindowController? {
        ensureMainWindowVisible()
        return mainWindowController
    }

    // MARK: - Menu
    //
    // Klip is an LSUIElement accessory app and has no menu bar to copy, so the
    // structure here follows Apple's own conventions and Klip's *wording* ones:
    // "Settings…" rather than "Preferences…", a real ellipsis on anything that opens
    // a window or a dialog and none on anything immediate, Title Case throughout, and
    // the version read from the bundle rather than baked in.
    //
    // Every item below is wired to something that exists. Enablement is decided by
    // MainWindowController.validateMenuItem, so items grey out when they have nothing
    // to act on instead of failing silently.

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        mainMenu.addItem(appMenuItem())
        mainMenu.addItem(fileMenuItem())
        mainMenu.addItem(editMenuItem())
        mainMenu.addItem(viewMenuItem())
        mainMenu.addItem(modeMenuItem())
        mainMenu.addItem(windowMenuItem(assigningTo: NSApp))
        mainMenu.addItem(helpMenuItem())
        NSApp.mainMenu = mainMenu
    }

    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()

        let about = NSMenuItem(title: "About Squish", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        let notifications = NSMenuItem(title: "Notifications…", action: #selector(showNotificationPermission), keyEquivalent: "")
        notifications.target = self
        menu.addItem(notifications)

        menu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(servicesItem)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Squish", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Squish", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    private func fileMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        let addFiles = NSMenuItem(title: "Add Files…", action: #selector(addFiles), keyEquivalent: "o")
        addFiles.target = self
        menu.addItem(addFiles)

        let addFolder = NSMenuItem(title: "Add Folder…", action: #selector(addFolder), keyEquivalent: "O")
        addFolder.target = self
        addFolder.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(addFolder)

        menu.addItem(.separator())

        // Target nil so this validates against the window controller in the responder
        // chain - and greys out when the list is empty or a pass is already running.
        let compress = NSMenuItem(title: "Compress",
                                  action: #selector(MainWindowController.compress(_:)),
                                  keyEquivalent: "\r")
        compress.keyEquivalentModifierMask = [.command]
        menu.addItem(compress)

        menu.addItem(.separator())

        let reveal = NSMenuItem(title: "Reveal in Finder",
                                action: #selector(MainWindowController.revealInFinder(_:)),
                                keyEquivalent: "r")
        reveal.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(reveal)

        let remove = NSMenuItem(title: "Remove from List",
                                action: #selector(MainWindowController.removeFromList(_:)),
                                keyEquivalent: "\u{8}")
        remove.keyEquivalentModifierMask = [.command]
        menu.addItem(remove)

        let clear = NSMenuItem(title: "Clear List",
                               action: #selector(MainWindowController.clearList(_:)),
                               keyEquivalent: "")
        menu.addItem(clear)

        menu.addItem(.separator())
        menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        item.submenu = menu
        return item
    }

    private func editMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(.separator())
        // Routes to whatever is first responder - the file list, normally, which
        // selects every row.
        menu.addItem(withTitle: "Select All", action: #selector(NSResponder.selectAll(_:)), keyEquivalent: "a")
        item.submenu = menu
        return item
    }

    /// Two ways to look at a file: the pane inside the main window, which follows the
    /// selection, and a standalone window for serious pixel-peeping. Both validate
    /// against MainWindowController, so the window item greys out with no selection.
    private func viewMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        // Title and checkmark are set by MainWindowController.validateMenuItem.
        let pane = NSMenuItem(title: "Show Comparison Pane",
                              action: #selector(MainWindowController.toggleComparisonPane(_:)),
                              keyEquivalent: "c")
        pane.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pane)

        menu.addItem(.separator())

        let window = NSMenuItem(title: "Open Comparison Window…",
                                action: #selector(MainWindowController.compareSelected(_:)),
                                keyEquivalent: "y")
        window.keyEquivalentModifierMask = [.command]
        menu.addItem(window)

        menu.addItem(.separator())

        // The app follows the system by default. The override is here rather than
        // buried in Settings because it is a judgement aid while comparing images,
        // not a set-once configuration choice.
        let appearanceItem = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu(title: "Appearance")
        for setting in AppearanceSetting.allCases {
            let entry = NSMenuItem(title: setting.displayName,
                                   action: #selector(selectAppearance(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = setting.rawValue
            entry.state = Preferences.shared.appearance == setting ? .on : .off
            appearanceMenu.addItem(entry)
        }
        appearanceItem.submenu = appearanceMenu
        menu.addItem(appearanceItem)

        item.submenu = menu
        return item
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let setting = AppearanceSetting(rawValue: raw) else { return }
        Preferences.shared.appearance = setting
        for sibling in sender.menu?.items ?? [] {
            sibling.state = (sibling.representedObject as? String) == raw ? .on : .off
        }
    }

    @objc private func checkForUpdates() {
        Task { await UpdateChecker.shared.checkNow() }
    }

    private func modeMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Mode")
        for (index, mode) in SquishMode.allCases.enumerated() {
            let modeItem = NSMenuItem(title: mode.displayName,
                                      action: #selector(MainWindowController.selectModeMenuItem(_:)),
                                      keyEquivalent: "\(index + 1)")
            modeItem.tag = index
            // A radio group: validateMenuItem ticks whichever one the window is on.
            menu.addItem(modeItem)
        }
        item.submenu = menu
        return item
    }

    private func windowMenuItem(assigningTo app: NSApplication) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        app.windowsMenu = menu
        return item
    }

    private func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        let help = NSMenuItem(title: "Squish Help", action: #selector(showHelp), keyEquivalent: "?")
        help.target = self
        menu.addItem(help)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    // MARK: - Menu actions

    @objc private func addFiles() {
        mainWindow?.presentAddFilesPanel()
    }

    @objc private func addFolder() {
        mainWindow?.presentAddFolderPanel()
    }

    @objc private func showSettings() {
        if preferencesWindowController == nil {
            preferencesWindowController = PreferencesWindowController()
        }
        preferencesWindowController?.showWindow(nil)
        preferencesWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showHelp() {
        HelpWindowController.shared.show()
    }

    /// Klip has no About panel at all - version + a Changelog link in its settings
    /// footer is its whole About story, and there is no CHANGELOG to mirror here.
    /// So: the standard panel, filled from the bundle.
    @objc private func showAbout() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: AppInfo.name,
            .applicationVersion: AppInfo.shortVersion,
            .version: AppInfo.buildNumber
        ]
        let blurb = NSAttributedString(
            string: "Native image compression. mozjpeg, cwebp and a perceptual "
                  + "quality search, all bundled - no Homebrew, no network.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        options[.credits] = blurb
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The only system permission Squish has any use for. Everything else it does is
    /// ordinary file access on files the user handed it.
    @objc private func showNotificationPermission() {
        Task { @MainActor in
            let permission = await NotificationManager.currentPermission()
            switch permission {
            case .notDetermined:
                let result = await NotificationManager.requestPermission()
                presentNotificationAlert(for: result)
            default:
                presentNotificationAlert(for: permission)
            }
        }
    }

    private func presentNotificationAlert(for permission: NotificationManager.Permission) {
        let alert = NSAlert()
        alert.messageText = "Notifications: \(permission.summary)"
        var showSettingsButton = false

        switch permission {
        case .granted:
            alert.informativeText = "Squish will post a notification when a batch finishes."
        case .denied:
            alert.alertStyle = .informational
            alert.informativeText = "macOS is blocking Squish's notifications. Everything else "
                                  + "works normally - the footer and the file list still show what happened. "
                                  + "You can turn them back on in System Settings."
            showSettingsButton = true
        case .notDetermined:
            alert.informativeText = "macOS didn't record an answer. Try again, or allow Squish "
                                  + "in System Settings > Notifications."
            showSettingsButton = true
        case .unavailable:
            // Never offer a prompt that cannot succeed: an ad-hoc signature often
            // can't get a notification centre at all, and Squish falls back to a
            // plain system notification instead.
            alert.informativeText = "This copy of Squish is ad-hoc signed, so macOS won't give it "
                                  + "the notification centre. Squish falls back to a standard system "
                                  + "notification when a batch finishes, so you'll still be told."
        }

        alert.addButton(withTitle: "OK")
        if showSettingsButton {
            alert.addButton(withTitle: "Open System Settings")
        }

        let response = alert.runModal()
        if showSettingsButton, response == .alertSecondButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - NSServices fallback
    //
    // Info.plist (written by scripts/build-app.sh) declares three NSServices entries
    // accepting NSFilenamesPboardType. Like every other route in, these now *add* the
    // files and preselect the mode rather than compressing immediately - the whole
    // point of the window is that you look before you commit. The Finder Quick Action
    // in quickactions/ remains the one-shot, no-window route.

    @objc func compressForWeb(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handleService(pasteboard: pasteboard, mode: .jpeg)
    }

    @objc func compressToWebP(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handleService(pasteboard: pasteboard, mode: .webp)
    }

    @objc func compressVisuallyLossless(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        handleService(pasteboard: pasteboard, mode: .vlossless)
    }

    /// Right-clicking in Finder compresses immediately. "Squish to JPEG" reads as an
    /// instruction, not an invitation to open a window and press another button, and
    /// it is non-destructive by default (a new file alongside the original), so there
    /// is nothing to confirm. Opening the window is what dropping on the Dock icon is
    /// for, when you do want to look before committing.
    private func handleService(pasteboard: NSPasteboard, mode: SquishMode) {
        // Declaring NSSendFileTypes is what makes Finder offer these at all, but the
        // pasteboard can then arrive as either file URLs or the legacy filename list,
        // depending on how the selection was made. Accept both.
        var paths: [String] = []
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] {
            paths = urls.filter(\.isFileURL).map(\.path)
        }
        if paths.isEmpty {
            let filenamesType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
            paths = pasteboard.propertyList(forType: filenamesType) as? [String] ?? []
        }
        guard !paths.isEmpty else {
            NotificationManager.notify(title: "Squish", body: "No files were received from Finder.")
            return
        }
        let prefs = Preferences.shared
        let settings = prefs.encodeSettings(mode: mode,
                                            quality: Preferences.defaultQuality,
                                            target: Preferences.defaultTarget)
        var args: [String] = [mode.cliArgument]
        args += settings.encodeArguments
        switch prefs.outputBehavior {
        case .alongside:
            args += ["--suffix", prefs.suffix]
        case .folder:
            if prefs.outputFolderPath.isEmpty {
                args += ["--suffix", prefs.suffix]
            } else {
                args += ["--out", prefs.outputFolderPath]
            }
        case .inplace:
            args.append("--inplace")
        }
        args += ["-r", "--json"]
        args += paths

        Task { @MainActor in
            await Self.runService(arguments: args, mode: mode)
        }
    }

    private static func runService(arguments: [String], mode: SquishMode) async {
        do {
            let output = try await SquishCLI.run(arguments: arguments)
            var count = 0, failed = 0
            var bytesIn: Int64 = 0, bytesOut: Int64 = 0
            for line in output.stdout.split(separator: "\n") {
                guard let data = line.data(using: .utf8),
                      let r = try? JSONDecoder().decode(RunResult.self, from: data) else { continue }
                if r.ok {
                    count += 1
                    bytesIn += r.bytesIn ?? 0
                    bytesOut += r.bytesOut ?? 0
                } else {
                    failed += 1
                }
            }
            guard count > 0 || failed > 0 else {
                NotificationManager.notify(title: "Squish", body: "Nothing to compress.")
                return
            }
            if count > 0 {
                let saved = bytesIn > 0 ? Int((Double(bytesIn - bytesOut) / Double(bytesIn) * 100).rounded()) : 0
                var body = "\(count) \(count == 1 ? "image" : "images") · "
                    + "\(ByteFormat.string(for: bytesIn)) → \(ByteFormat.string(for: bytesOut)) · saved \(saved)%"
                if failed > 0 { body += " · \(failed) failed" }
                NotificationManager.notify(title: "Squish to \(mode.displayName)", body: body)
            } else {
                NotificationManager.notify(title: "Squish to \(mode.displayName)",
                                           body: "\(failed) \(failed == 1 ? "file" : "files") could not be compressed.")
            }
        } catch {
            NotificationManager.notify(title: "Squish", body: error.localizedDescription)
        }
    }
}
