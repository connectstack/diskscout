import SwiftUI
import AppKit

@main
struct DiskScoutApp: App {
    @StateObject private var model = AppModel.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        Window("DiskScout", id: "main") {
            ContentView()
                .environmentObject(model)
                .onAppear { NSApp.activate(ignoringOtherApps: true) }
                .onChange(of: model.showHistory) { _, show in
                    if show { openWindow(id: "history"); model.showHistory = false }
                }
                .onChange(of: model.mediaRequest) { _, url in
                    if let url { openWindow(id: "media", value: url); model.mediaRequest = nil }
                }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1240, height: 780)
        .commands { commands }

        Window("Cleanup History", id: "history") {
            HistoryView(trash: model.trash).environmentObject(model)
        }
        .defaultSize(width: 720, height: 460)

        WindowGroup("Media", id: "media", for: URL.self) { $url in
            if let url {
                MediaGalleryView(root: url).environmentObject(model)
            }
        }
        .defaultSize(width: 1000, height: 700)

        Settings {
            SettingsView(settings: model.settings, license: model.license)
        }
    }

    @CommandsBuilder
    private var commands: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About DiskScout") { showAbout() }
        }
        CommandGroup(after: .appInfo) {
            Divider()
            Button("Activate License…") { model.showUpgrade = true }
            Button("Welcome to DiskScout") { model.showWelcome = true }
        }
        CommandGroup(replacing: .newItem) {
            Button("Scan Folder…") { model.chooseFolder() }.keyboardShortcut("o")
            Button("Rescan") { model.rescan() }.keyboardShortcut("r")
            Button("Stop Scan") { model.stop() }.keyboardShortcut(".")
        }
        CommandMenu("Item") {
            Button("Quick Look") { model.quickLookSelection() }.keyboardShortcut("y")
            Button("Show in Finder") { model.revealSelection() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Show Media Inside") { model.showMediaForSelection() }.keyboardShortcut("m", modifiers: [.command, .shift])
            Button("Enclosing Folder") { model.engine.goUp() }.keyboardShortcut(.upArrow, modifiers: .command)
            Divider()
            Button("Move to Trash…") { model.requestTrashSelection() }.keyboardShortcut(.delete, modifiers: .command)
        }
        CommandGroup(after: .sidebar) {
            ForEach(ViewMode.allCases) { m in
                Button(m.rawValue) { withAnimation(.snappyUI) { model.mode = m } }
                    .keyboardShortcut(m.shortcut, modifiers: .command)
                    .disabled(m.needsScan && model.engine.root == nil)
            }
            Divider()
            Button("Toggle Inspector") { withAnimation(.snappyUI) { model.showInspector.toggle() } }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Smart Clean") { model.select(location: QuickLocations.smartClean) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
        CommandGroup(after: .windowArrangement) {
            Button("Cleanup History") { openWindow(id: "history") }.keyboardShortcut("h", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
            Button("DiskScout Website") { NSWorkspace.shared.open(URL(string: "https://diskscout.app")!) }
        }
    }

    private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "DiskScout"
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "2.0"
        alert.informativeText = "Version \(version)\n\nKnow what's safe to delete.\nDiskScout finds what's eating your Mac's storage and explains, for every item, whether removing it is safe.\n\n© 2026 DiskScout. All rights reserved."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
