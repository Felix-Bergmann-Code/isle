import AppKit
import SwiftUI

@main
enum IsleMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()
    private var windows: NotchWindowManager?
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        env.openSettings = { [weak self] in self?.showSettings() }
        let wm = NotchWindowManager(env: env)
        wm.start()
        windows = wm
        installStatusItem()
        // Services (and their permission prompts) after the island is on screen.
        DispatchQueue.main.async { [env] in Demo.isEnabled ? Demo.populate(env) : env.start() }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "capsule.portrait.fill", accessibilityDescription: "Isle")?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        item.button?.image?.isTemplate = true
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Island", action: #selector(openIsland), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Isle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        statusItem = item
    }

    @objc private func openIsland() {
        env.vm.open()
        // Close again once the pointer is elsewhere for a moment.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, !self.env.vm.isHovering else { return }
            self.windows?.reposition()
        }
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView(env: env))
            let w = NSWindow(contentViewController: host)
            w.title = "Isle Settings"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
