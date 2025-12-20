import Cocoa

class FloatingPanel: NSPanel {

    init(contentRect: NSRect) {
        // Use .borderless for a completely custom appearance without system title bar
        // .nonactivatingPanel prevents the window from activating the app (making the menu bar change)
        // effectively unless we explicitly want it to.
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
  
        // Level: .mainMenu places it above standard windows and the dock
        self.level = .mainMenu

        // Collection Behavior:
        // .canJoinAllSpaces: The window appears on all Mission Control spaces
        // .fullScreenAuxiliary: Allows the window to appear over full-screen apps
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Visuals: Transparent background so SwiftUI can control the shape (rounded corners)
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true

        // Behavior
        self.hidesOnDeactivate = true  // Automatically hide when the user clicks outside
        self.isReleasedWhenClosed = false  // Keep the window instance alive when closed
        self.isMovableByWindowBackground = false  // Fixed position (usually)

        // Center the window initially
        self.center()
    }

    // Essential: Allow a borderless window to receive keyboard input
    override var canBecomeKey: Bool {
        return true
    }

    override var canBecomeMain: Bool {
        return true
    }
}
