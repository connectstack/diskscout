import SwiftUI

struct SidebarLocation: Identifiable, Hashable {
    let id: String
    let name: String
    let systemImage: String
    let color: Color
    let url: URL
    let section: Section

    var isSmartClean: Bool { id == "smart-clean" }

    enum Section: String, CaseIterable {
        case tools = "DiskScout"
        case mac = "This Mac"
        case home = "Home"
        case library = "Library"
    }
}

enum QuickLocations {
    static let all: [SidebarLocation] = {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func loc(_ name: String, _ icon: String, _ color: Color, _ url: URL, _ section: SidebarLocation.Section) -> SidebarLocation {
            SidebarLocation(id: url.path, name: name, systemImage: icon, color: color, url: url, section: section)
        }
        let smart = SidebarLocation(id: "smart-clean", name: "Smart Clean", systemImage: "sparkles", color: Color(red: 0.74, green: 0.47, blue: 1.0), url: home, section: .tools)
        return [
            smart,
            loc("Whole Mac", "internaldrive.fill", Color(red: 0.55, green: 0.58, blue: 0.68), URL(fileURLWithPath: "/"), .mac),
            loc("Applications", "square.grid.2x2.fill", Color(red: 0.36, green: 0.58, blue: 1.0), URL(fileURLWithPath: "/Applications"), .mac),
            loc("Users", "person.2.fill", Color(red: 0.27, green: 0.72, blue: 0.95), URL(fileURLWithPath: "/Users"), .mac),
            loc("System Library", "books.vertical.fill", Color(red: 0.52, green: 0.52, blue: 0.62), URL(fileURLWithPath: "/Library"), .mac),
            loc("Home", "house.fill", Color(red: 0.30, green: 0.60, blue: 1.0), home, .home),
            loc("Desktop", "menubar.dock.rectangle", Color(red: 0.27, green: 0.72, blue: 0.95), home.appendingPathComponent("Desktop"), .home),
            loc("Documents", "doc.fill", Color(red: 1.0, green: 0.76, blue: 0.28), home.appendingPathComponent("Documents"), .home),
            loc("Downloads", "arrow.down.circle.fill", Color(red: 0.20, green: 0.78, blue: 0.45), home.appendingPathComponent("Downloads"), .home),
            loc("Movies", "film.fill", Color(red: 0.74, green: 0.47, blue: 1.0), home.appendingPathComponent("Movies"), .home),
            loc("Music", "music.note", Color(red: 1.0, green: 0.47, blue: 0.58), home.appendingPathComponent("Music"), .home),
            loc("Pictures", "photo.fill", Color(red: 0.96, green: 0.56, blue: 0.27), home.appendingPathComponent("Pictures"), .home),
            loc("Trash", "trash.fill", Color(red: 0.55, green: 0.58, blue: 0.68), home.appendingPathComponent(".Trash"), .home),
            loc("Caches", "memorychip.fill", Color(red: 0.36, green: 0.58, blue: 1.0), home.appendingPathComponent("Library/Caches"), .library),
            loc("Application Support", "shippingbox.fill", Color(red: 1.0, green: 0.62, blue: 0.20), home.appendingPathComponent("Library/Application Support"), .library),
            loc("Containers", "cube.box.fill", Color(red: 0.74, green: 0.47, blue: 1.0), home.appendingPathComponent("Library/Containers"), .library),
            loc("Developer", "hammer.fill", Color(red: 0.45, green: 0.84, blue: 0.47), home.appendingPathComponent("Library/Developer"), .library),
            loc("Logs", "doc.text.magnifyingglass", Color(red: 0.62, green: 0.67, blue: 0.78), home.appendingPathComponent("Library/Logs"), .library),
            loc("Library", "books.vertical.fill", Color(red: 0.52, green: 0.52, blue: 0.62), home.appendingPathComponent("Library"), .library),
        ]
    }()

    static func itemsIn(_ section: SidebarLocation.Section) -> [SidebarLocation] {
        all.filter { $0.section == section }
    }

    static var smartClean: SidebarLocation { all[0] }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var sizer: SidebarSizer
    @ObservedObject var cleaner: CleanupScanner
    @ObservedObject var license: LicenseManager
    @ObservedObject var trash: TrashManager

    var body: some View {
        VStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedLocation }, set: { model.select(location: $0) })) {
                ForEach(SidebarLocation.Section.allCases, id: \.self) { section in
                    Section {
                        ForEach(QuickLocations.itemsIn(section)) { loc in
                            SidebarRow(
                                loc: loc,
                                size: loc.isSmartClean ? (cleaner.items.isEmpty ? nil : cleaner.totalSafe) : sizer.sizes[loc.url],
                                isLoading: loc.isSmartClean ? cleaner.isScanning : sizer.inProgress.contains(loc.url),
                                isUnreadable: sizer.unreadable.contains(loc.url),
                                highlight: loc.isSmartClean
                            )
                            .tag(loc)
                        }
                    } header: {
                        if section != .tools { Text(section.rawValue) }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if trash.lifetimeFreed > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "leaf.fill").foregroundStyle(SafetyLevel.safe.color)
                    Text("Freed with DiskScout")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    BytesText(bytes: trash.lifetimeFreed, font: .caption.weight(.semibold))
                }
            }
            licensePill
        }
        .padding(12)
    }

    @ViewBuilder
    private var licensePill: some View {
        switch license.status {
        case .licensed(let info):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(SafetyLevel.safe.color)
                VStack(alignment: .leading, spacing: 1) {
                    Text("DiskScout Pro").font(.caption.weight(.semibold))
                    Text(info.email).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
        case .trial(let days):
            Button { model.showUpgrade = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark").foregroundStyle(.secondary)
                    Text("Trial · \(days) day\(days == 1 ? "" : "s") left").font(.caption)
                    Spacer()
                    Text("Upgrade").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.subtleFill))
            }
            .buttonStyle(.plain)
        case .expired:
            Button { model.showUpgrade = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").foregroundStyle(SafetyLevel.caution.color)
                    Text("Trial ended").font(.caption)
                    Spacer()
                    Text("Unlock").font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor))
                }
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(SafetyLevel.caution.color.opacity(0.12)))
            }
            .buttonStyle(.plain)
        }
    }
}

private struct SidebarRow: View {
    let loc: SidebarLocation
    let size: Int64?
    let isLoading: Bool
    let isUnreadable: Bool
    let highlight: Bool

    var body: some View {
        HStack(spacing: 9) {
            IconTile(systemImage: loc.systemImage, color: loc.color, size: 22)
            Text(loc.name)
                .font(.system(size: 13, weight: highlight ? .semibold : .regular))
                .lineLimit(1)
            Spacer(minLength: 6)
            trailing
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var trailing: some View {
        if let size {
            Text(ByteFormat.string(size))
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(highlight ? SafetyLevel.safe.color : SizeTier(size).color)
                .contentTransition(.numericText())
                .lineLimit(1)
        } else if isLoading {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 14, height: 14)
        } else if isUnreadable {
            Image(systemName: "lock.fill")
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .help("Permission denied — grant Full Disk Access to see this folder's size")
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
