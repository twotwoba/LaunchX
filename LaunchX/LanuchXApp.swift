import Combine
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
    var onboardingWindow: NSWindow?
    var isQuitting = false

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
        checkPermissions()
    }

    func checkPermissions() {
        let isFirstLaunch = !UserDefaults.standard.bool(forKey: "hasLaunchedBefore")

        if isFirstLaunch {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            // Open onboarding on first launch
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.openOnboarding()
            }
        } else {
            // Just check permissions state without forcing UI
            PermissionService.shared.checkAllPermissions()
        }
    }

    func openOnboarding() {
        if onboardingWindow == nil {
            let rootView = OnboardingView { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
                // Show the panel after onboarding is done
                PanelManager.shared.togglePanel()
            }

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 600, height: 550),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered, defer: false)
            window.center()
            window.setFrameAutosaveName("OnboardingWindow")
            window.contentView = NSHostingView(rootView: rootView)
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.title = "Welcome to LaunchX"

            // Hide zoom and minimize buttons for a cleaner look
            window.standardWindowButton(.zoomButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true

            onboardingWindow = window
        }

        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
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
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(explicitQuit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func togglePanel() {
        PanelManager.shared.togglePanel()
    }

    @objc func openSettings() {
        PanelManager.shared.hidePanel(deactivateApp: false)
        // Send action to open the Settings window defined in the App struct
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func explicitQuit() {
        isQuitting = true
        NSApp.terminate(nil)
    }

    // Intercept termination request (Cmd+Q) to keep the app running in the background
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isQuitting {
            return .terminateNow
        }

        // Close all windows (Settings, Onboarding, etc.) but keep the app running
        for window in NSApp.windows {
            window.close()
        }

        // Hide the application
        NSApp.hide(nil)

        return .terminateCancel
    }
}
