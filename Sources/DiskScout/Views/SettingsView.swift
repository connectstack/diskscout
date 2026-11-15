import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView {
            GeneralSettings(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            ExclusionsSettings(settings: settings)
                .tabItem { Label("Exclusions", systemImage: "eye.slash") }
        }
        .frame(width: 520, height: 360)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var settings: AppSettings
    var body: some View {
        Form {
            Section("Scanning") {
                Toggle("Include hidden files and folders", isOn: $settings.showHiddenFiles)
                Text("Hidden folders such as ~/.npm or ~/.cache are often where developer junk hides. Turning this off makes sizes smaller than Finder's.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Open DiskScout in", selection: $settings.defaultMode) {
                    ForEach(ViewMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
            }
            Section("Duplicates") {
                Picker("Ignore files smaller than", selection: $settings.duplicateMinSizeKB) {
                    Text("8 KB").tag(8); Text("64 KB").tag(64); Text("1 MB").tag(1024); Text("10 MB").tag(10240)
                }
            }
            Section("Treemap") {
                Picker("Colour tiles by", selection: Binding(get: { settings.treemapColors }, set: { settings.treemapColors = $0 })) {
                    ForEach(TreemapColorMode.allCases) { Text($0.rawValue).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ExclusionsSettings: View {
    @ObservedObject var settings: AppSettings
    @State private var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Excluded folders are skipped by every scan. Useful for cloud drives or network shares.")
                .font(.callout).foregroundStyle(.secondary)
            List(selection: $selection) {
                ForEach(settings.excludedPaths, id: \.self) { p in
                    Label(p, systemImage: "folder").lineLimit(1).truncationMode(.middle).tag(p)
                }
            }
            .frame(minHeight: 180)
            HStack {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = false
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    if panel.runModal() == .OK {
                        var ex = settings.excludedPaths
                        for u in panel.urls where !ex.contains(u.path) { ex.append(u.path) }
                        settings.excludedPaths = ex
                    }
                } label: { Image(systemName: "plus") }
                Button {
                    if let s = selection { settings.excludedPaths.removeAll { $0 == s }; selection = nil }
                } label: { Image(systemName: "minus") }
                .disabled(selection == nil)
                Spacer()
            }
        }
        .padding(16)
    }
}
