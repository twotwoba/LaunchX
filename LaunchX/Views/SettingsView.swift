import Carbon
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gear")
                }

            // Placeholder for other settings
            Text("Search & Indexing")
                .tabItem {
                    Label("Search", systemImage: "magnifyingglass")
                }

            Text("Extensions")
                .tabItem {
                    Label("Extensions", systemImage: "puzzlepiece")
                }
        }
        .frame(width: 550, height: 450)
        .padding()
        .onAppear {
            PanelManager.shared.hidePanel(deactivateApp: false)
        }
    }
}

struct GeneralSettingsView: View {
    // Window Mode persistence
    @AppStorage("defaultWindowMode") private var windowModeString: String = "simple"

    // Launch at Login state
    @State private var isLaunchAtLoginEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                // 1. Launch at Login
                Toggle("Open at Login:", isOn: $isLaunchAtLoginEnabled)
                    .toggleStyle(CheckboxToggleStyle())
                    .onChange(of: isLaunchAtLoginEnabled) { newValue in
                        updateLaunchAtLogin(enabled: newValue)
                    }
                    .onAppear {
                        checkLaunchAtLoginStatus()
                    }

                // 2. HotKey Configuration
                HStack {
                    Text("Activation Hotkey:")
                    Spacer()
                    HotKeyRecorderView()
                }
            }

            Divider()
                .padding(.vertical, 10)

            Section {
                // 3. Default Window Mode
                VStack(alignment: .leading, spacing: 10) {
                    Text("Default Window Mode:")

                    Picker("", selection: $windowModeString) {
                        Text("Simple").tag("simple")
                        Text("Full").tag("full")
                    }
                    .pickerStyle(RadioGroupPickerStyle())
                    .labelsHidden()

                    // Visual Representation
                    HStack(spacing: 30) {
                        VStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(radius: 1)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.8))
                                        .frame(height: 8)  // Search bar
                                    Spacer()
                                }
                                .padding(6)
                            }
                            .frame(width: 80, height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        windowModeString == "simple" ? Color.blue : Color.clear,
                                        lineWidth: 2)
                            )

                            Text("Simple")
                                .font(.caption)
                                .foregroundColor(
                                    windowModeString == "simple" ? .primary : .secondary)
                        }
                        .onTapGesture { windowModeString = "simple" }

                        VStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(Color(nsColor: .controlBackgroundColor))
                                    .shadow(radius: 1)
                                VStack(spacing: 2) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Color.blue.opacity(0.8))
                                        .frame(height: 8)  // Search bar

                                    // List items
                                    ForEach(0..<3) { _ in
                                        RoundedRectangle(cornerRadius: 1)
                                            .fill(Color.secondary.opacity(0.2))
                                            .frame(height: 4)
                                    }
                                    Spacer()
                                }
                                .padding(6)
                            }
                            .frame(width: 80, height: 60)
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        windowModeString == "full" ? Color.blue : Color.clear,
                                        lineWidth: 2)
                            )

                            Text("Full")
                                .font(.caption)
                                .foregroundColor(windowModeString == "full" ? .primary : .secondary)
                        }
                        .onTapGesture { windowModeString = "full" }
                    }
                    .padding(.top, 5)
                }
            }
        }
        .padding(20)
    }

    // MARK: - Launch at Login Logic

    private func checkLaunchAtLoginStatus() {
        if #available(macOS 13.0, *) {
            isLaunchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        }
    }

    private func updateLaunchAtLogin(enabled: Bool) {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                print("Failed to update launch at login: \(error)")
                // Revert UI if failed
                checkLaunchAtLoginStatus()
            }
        }
    }
}

// MARK: - HotKey Recorder

struct HotKeyRecorderView: View {
    @ObservedObject var hotKeyService = HotKeyService.shared
    @State private var isRecording = false
    @State private var monitor: Any?
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: {
            isRecording.toggle()
        }) {
            HStack {
                if isRecording {
                    Text("Press keys...")
                        .foregroundColor(.secondary)
                } else {
                    Text(
                        HotKeyService.displayString(
                            for: hotKeyService.currentModifiers,
                            keyCode: hotKeyService.currentKeyCode
                        )
                    )
                    .fontWeight(.medium)
                }

                if isRecording {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 16, height: 16)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 140)
        }
        .buttonStyle(.bordered)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isRecording ? Color.blue : Color.clear, lineWidth: 2)
        )
        .onChange(of: isRecording) { recording in
            if recording {
                startRecording()
            } else {
                stopRecording()
            }
        }
    }

    private func startRecording() {
        // Monitor local events for key presses
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // 1. Ignore events that are just modifier keys
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
                return event
            }

            // 2. Handle Escape to cancel
            if event.keyCode == kVK_Escape {
                isRecording = false
                return nil
            }

            // 3. Capture valid hotkey
            let modifiers = HotKeyService.carbonModifiers(from: event.modifierFlags)
            let keyCode = UInt32(event.keyCode)

            hotKeyService.registerHotKey(keyCode: keyCode, modifiers: modifiers)

            isRecording = false
            return nil  // Consume event
        }
    }

    private func stopRecording() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}
