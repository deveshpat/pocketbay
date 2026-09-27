import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var controller: MainWindowController!
    private var pendingOpen: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = MainWindowController()
        buildMenu()
        controller.showWindow(nil)
        controller.window?.makeFirstResponder(controller.screen)
        NSApp.activate()
        controller.start()
        if !pendingOpen.isEmpty { controller.install(pendingOpen) }
    }

    /// APKs dropped on the Dock icon or opened with Pocketbay.
    func application(_ application: NSApplication, open urls: [URL]) {
        let apks = urls.filter { $0.pathExtension.lowercased() == "apk" }
        if let controller { controller.install(apks) } else { pendingOpen += apks }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controller.manager.pid != nil else { return .terminateNow }
        Task { @MainActor in
            await controller.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: Menu

    private func buildMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "About Pocketbay", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Pocketbay", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Pocketbay", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "Pocketbay")

        // Standard selectors: the screen forwards them to Android, and text fields in
        // the controls editor handle them as usual.
        let edit = NSMenu()
        edit.addItem(withTitle: "Cut", action: #selector(ScreenView.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(ScreenView.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(ScreenView.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "Edit")

        let device = NSMenu()
        device.addItem(item("Back", #selector(back), "["))
        device.addItem(item("Home", #selector(home), "H", [.command, .shift]))
        device.addItem(item("Recent Apps", #selector(recents), "R", [.command, .shift]))
        device.addItem(.separator())
        device.addItem(item("Volume Up", #selector(volumeUp), "="))
        device.addItem(item("Volume Down", #selector(volumeDown), "-"))
        device.addItem(item("Rotate", #selector(rotate), "r"))
        device.addItem(.separator())
        device.addItem(item("Take Screenshot", #selector(screenshot), "S", [.command, .shift]))
        device.addItem(item("Install App (.apk)…", #selector(installApk), "o"))
        main.addItem(submenu: device, title: "Device")

        let controls = NSMenu()
        controls.addItem(item("Game Controls On", #selector(toggleKeymap), "k"))
        controls.addItem(item("Show Key Hints", #selector(toggleHints), "/"))
        controls.addItem(item("Edit Game Controls…", #selector(editKeymap), "e"))
        controls.addItem(.separator())
        let layouts = NSMenuItem(title: "Layout", action: nil, keyEquivalent: "")
        layouts.submenu = controller.layoutsMenu
        controls.addItem(layouts)
        main.addItem(submenu: controls, title: "Controls")

        let view = NSMenu()
        view.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        main.addItem(submenu: view, title: "View")

        let window = NSMenu()
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        main.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key.lowercased())
        i.keyEquivalentModifierMask = mods
        return i
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(toggleKeymap): menuItem.state = controller.keymapEnabled ? .on : .off
        case #selector(toggleHints): menuItem.state = controller.showKeyHints ? .on : .off
        case #selector(editKeymap): menuItem.state = controller.isEditingKeymap ? .on : .off
        default: break
        }
        return true
    }

    @objc private func back() { controller.perform(.back) }
    @objc private func home() { controller.perform(.home) }
    @objc private func recents() { controller.perform(.recents) }
    @objc private func volumeUp() { controller.perform(.volumeUp) }
    @objc private func volumeDown() { controller.perform(.volumeDown) }
    @objc private func rotate() { controller.perform(.rotate) }
    @objc private func screenshot() { controller.perform(.screenshot) }
    @objc private func installApk() { controller.perform(.installApk) }
    @objc private func toggleKeymap() { controller.perform(.keymapToggle) }
    @objc private func toggleHints() { controller.showKeyHints.toggle() }
    @objc private func editKeymap() { controller.perform(.keymapEdit) }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        submenu.title = title
        i.submenu = submenu
        addItem(i)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
