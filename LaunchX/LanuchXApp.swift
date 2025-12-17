import SwiftUI

@main
struct LaunchXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // We use Settings to avoid creating a default WindowGroup window.
        // The actual main interface is managed by PanelManager.
        Settings {
            SettingsView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing (Sierra+)
        NSWindow.allowsAutomaticWindowTabbing = false

        // 1. Initialize the Search Panel
        PanelManager.shared.setup(rootView: ContentView())

        // 2. Setup Global HotKey (Option + Space)
        HotKeyService.shared.setupGlobalHotKey()

        // 3. Bind HotKey Action
        HotKeyService.shared.onHotKeyPressed = {
            PanelManager.shared.togglePanel()
        }

        setupStatusItem()
    }

    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(
                systemSymbolName: "magnifyingglass", accessibilityDescription: "LaunchX")
        }

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Open LaunchX", action: #selector(togglePanel), keyEquivalent: "o"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func togglePanel() {
        PanelManager.shared.togglePanel()
    }

    @objc func openSettings() {
        PanelManager.shared.hidePanel(deactivateApp: false)
        NSApp.sendAction(Selector("showSettingsWindow:"), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func quitApp() {
        NSApp.terminate(nil)
    }
}
