import Carbon.HIToolbox
import Combine
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = SearchViewModel()
    @FocusState private var isFocused: Bool
    @AppStorage("defaultWindowMode") private var windowMode: String = "simple"
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Search Header
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 22))
                    .foregroundColor(.secondary)

                TextField("LaunchX Search...", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 26, weight: .light))
                    .disableAutocorrection(true)
                    .focused($isFocused)
                    .onSubmit {
                        viewModel.openSelected()
                    }
                    // Attach Key Event Monitor
                    .background(
                        KeyEventHandler { event in
                            handleKeyEvent(event)
                        }
                    )
            }
            .padding(20)

            // Results or Empty State
            if !viewModel.results.isEmpty {
                Divider()
                ResultsListView(viewModel: viewModel)
            } else if !viewModel.searchText.isEmpty {
                Divider()
                // No results state
                VStack {
                    Text("No results found.")
                        .foregroundColor(.secondary)
                        .padding()
                }
                Spacer()
            } else {
                Divider()
                if windowMode == "full" {
                    FullModeStartView()
                } else {
                    EmptyStateView()
                }
                Spacer()
            }
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
        .cornerRadius(16)
        .frame(width: 650, height: 500)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
        )
        // Force focus when window appears
        .onAppear {
            DispatchQueue.main.async { isFocused = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
            _ in
            // Re-focus when window becomes key (e.g. triggered via HotKey)
            DispatchQueue.main.async {
                isFocused = true
            }
        }
        .onReceive(PanelManager.shared.openSettingsPublisher) { _ in
            openSettings()
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Only handle key down
        guard event.type == .keyDown else { return event }

        switch Int(event.keyCode) {
        case kVK_UpArrow:
            viewModel.moveSelectionUp()
            return nil  // Consume event so TextField doesn't move cursor awkwardly
        case kVK_DownArrow:
            viewModel.moveSelectionDown()
            return nil
        case kVK_Escape:
            PanelManager.shared.hidePanel()
            return nil
        default:
            // Emacs-style navigation: Ctrl+N (Down), Ctrl+P (Up)
            if event.modifierFlags.contains(.control) {
                switch Int(event.keyCode) {
                case kVK_ANSI_N:
                    viewModel.moveSelectionDown()
                    return nil
                case kVK_ANSI_P:
                    viewModel.moveSelectionUp()
                    return nil
                default:
                    break
                }
            }
            return event
        }
    }
}

// MARK: - Results List

struct ResultsListView: View {
    @ObservedObject var viewModel: SearchViewModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(viewModel.results.enumerated()), id: \.element.id) {
                        index, item in
                        ResultRowView(item: item, isSelected: index == viewModel.selectedIndex)
                            .id(index)
                            .onTapGesture {
                                viewModel.selectedIndex = index
                                viewModel.openSelected()
                            }
                    }
                }
                .padding(.vertical, 10)
            }
            .onChange(of: viewModel.selectedIndex) { _, newIndex in
                proxy.scrollTo(newIndex, anchor: .center)
            }
        }
    }
}

struct ResultRowView: View {
    let item: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: item.icon)
                .resizable()
                .frame(width: 24, height: 24)

            VStack(alignment: .leading) {
                Text(item.name)
                    .font(.headline)
                    .foregroundColor(isSelected ? .white : .primary)
                Text(item.path)
                    .font(.caption)
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue : Color.clear)
        .contentShape(Rectangle())
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    var body: some View {
        HStack {
            Text("Type to search files...")
                .foregroundColor(.secondary)
                .font(.callout)
            Spacer()

            Text("⏎ to open")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 6)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                )
        }
        .padding(20)
    }
}

struct FullModeStartView: View {
    let commonApps: [(name: String, path: String)] = [
        ("Finder", "/System/Library/CoreServices/Finder.app"),
        ("Safari", "/Applications/Safari.app"),
        ("Terminal", "/System/Applications/Utilities/Terminal.app"),
        ("Notes", "/System/Applications/Notes.app"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Access")
                .font(.caption)
                .foregroundColor(.secondary)
                .padding(.horizontal, 20)
                .padding(.top, 15)

            HStack(spacing: 24) {
                ForEach(commonApps, id: \.path) { app in
                    Button(action: {
                        let url = URL(fileURLWithPath: app.path)
                        NSWorkspace.shared.open(url)
                        PanelManager.shared.hidePanel()
                    }) {
                        VStack(spacing: 8) {
                            if FileManager.default.fileExists(atPath: app.path) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                                    .resizable()
                                    .frame(width: 48, height: 48)
                            } else {
                                Image(systemName: "questionmark.app")
                                    .resizable()
                                    .frame(width: 48, height: 48)
                                    .foregroundColor(.secondary)
                            }

                            Text(app.name)
                                .font(.caption)
                                .foregroundColor(.primary)
                        }
                        .frame(width: 60)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHovering in
                        if isHovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
    }
}

// MARK: - Helpers

// Helper for Acrylic/Blur background
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// Helper to intercept key events
struct KeyEventHandler: NSViewRepresentable {
    let handler: (NSEvent) -> NSEvent?

    func makeNSView(context: Context) -> NSView {
        let view = KeyView()
        view.handler = handler
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    class KeyView: NSView {
        var handler: ((NSEvent) -> NSEvent?)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Remove existing monitor if any
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }

            if window != nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
                    [weak self] event in
                    return self?.handler?(event) ?? event
                }
            }
        }

        deinit {
            if let monitor = monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }
}
