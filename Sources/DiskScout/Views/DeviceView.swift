import SwiftUI
import AppKit

enum DevicePalette {
    static let device = Color(red: 0.27, green: 0.72, blue: 0.95)
    static let app = FileCategory.apps.color
    static let data = Color(red: 0.74, green: 0.47, blue: 1.0)
    static let media = FileCategory.photos.color
    static let system = FileCategory.system.color

    static func fullness(_ fraction: Double) -> Color {
        switch fraction {
        case 0.92...: return SafetyLevel.protected.color
        case 0.8...:  return SafetyLevel.caution.color
        case 0.6...:  return Color(red: 0.98, green: 0.80, blue: 0.25)
        default:      return SafetyLevel.safe.color
        }
    }
}

// MARK: - Detail area

/// Replaces the folder views while a connected iPhone or iPad is selected in the sidebar.
struct DeviceDetail: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice

    var body: some View {
        VStack(spacing: 0) {
            DeviceHero(device: device)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 10)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .bottom) {
                    if let transfer = model.deviceTransfer {
                        DeviceTransferPill(transfer: transfer).transition(.move(edge: .bottom).combined(with: .opacity))
                    } else if let toast = model.toast {
                        ToastView(toast: toast)
                    }
                }
                .animation(.snappyUI, value: model.deviceTransfer == nil)
        }
        .task(id: device.phase) { if device.isReady { device.loadDetails() } }
    }

    @ViewBuilder
    private var content: some View {
        switch device.phase {
        case .ready:
            VStack(spacing: 0) {
                DeviceTabBar(device: device)
                Divider()
                Group {
                    switch device.tab {
                    case .overview: DeviceContent(device: device)
                    case .photos: DevicePhotosTab(device: device)
                    case .files: DeviceFilesTab(device: device)
                    case .logs: DeviceLogsTab(device: device)
                    case .backup: DeviceBackupTab(device: device)
                    }
                }
                .id(device.tab)
                .transition(.opacity)
            }
        case .connecting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Connecting to \(device.displayName)…").font(.callout).foregroundStyle(.secondary)
            }
        case .needsTrust(let message):
            EmptyState(systemImage: "lock.iphone", title: "Waiting for your iPhone",
                       message: message + " DiskScout keeps checking, so there's nothing else to do here.",
                       action: ("Try Again", { device.retry() }))
        case .failed(let message):
            EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't read this device", message: message,
                       tint: SafetyLevel.caution.color, action: ("Try Again", { device.retry() }))
        }
    }
}

struct DeviceDisconnectedView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        EmptyState(systemImage: "cable.connector.slash", title: "iPhone disconnected",
                   message: "Plug it back in (and unlock it) to keep going. Nothing was changed on the device after it disconnected.",
                   tint: .secondary,
                   action: ("Back to Smart Clean", { model.select(location: QuickLocations.smartClean) }))
    }
}

// MARK: - Hero

struct DeviceHero: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice

    private var segments: [SegmentBar.Segment] {
        guard let info = device.info, device.appsLoaded else { return [] }
        var s = [
            SegmentBar.Segment(id: "apps", value: Double(device.totalAppSize), color: DevicePalette.app, label: "Apps"),
            SegmentBar.Segment(id: "data", value: Double(device.totalDataSize), color: DevicePalette.data, label: "Apps' Documents & Data"),
        ]
        if let media = device.media, media.total > 0 {
            s.append(.init(id: "media", value: Double(media.total), color: DevicePalette.media, label: "Photos & media"))
            if media.complete {
                let rest = info.used - device.totalAppSize - device.totalDataSize - media.total
                if rest > 0 { s.append(.init(id: "system", value: Double(rest), color: DevicePalette.system, label: "System & other")) }
            }
        }
        return s.sorted { $0.value > $1.value }
    }

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                if let info = device.info {
                    UsageRing(fraction: info.usedFraction, color: DevicePalette.fullness(info.usedFraction))
                } else {
                    Circle().stroke(Color.white.opacity(0.14), lineWidth: 9)
                    Image(systemName: device.systemImage).font(.system(size: 30)).foregroundStyle(.white.opacity(0.7))
                }
            }
            .frame(width: 86, height: 86)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Image(systemName: device.systemImage).font(.system(size: 13, weight: .semibold))
                    Text(device.displayName).font(.system(size: 15, weight: .semibold))
                    if let info = device.info {
                        Text("\(info.used.bytesString) used of \(info.capacity.bytesString)")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75))
                    }
                }
                .lineLimit(1)
                HStack(spacing: 8) {
                    if let info = device.info {
                        Label("\(info.free.bytesString) free", systemImage: "circle.dashed")
                        Text("\(info.model) · \(info.osName) \(info.osVersion)")
                    }
                    Label(device.link.isWiFi ? "Wi-Fi" : "USB", systemImage: device.link.isWiFi ? "wifi" : "cable.connector")
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)

                Spacer(minLength: 6)
                VStack(alignment: .leading, spacing: 6) {
                    Text(breakdownTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.65))
                    SegmentBar(segments: segments, height: 9, emptyColor: .white.opacity(0.12))
                    legend
                }
                .animation(.gentle, value: segments.map(\.id))
            }

            Spacer(minLength: 12)
            sideStats
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(height: 138)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.heroColors[1].opacity(0.35), radius: 14, y: 6)
    }

    private var breakdownTitle: String {
        guard device.isReady else { return "Storage" }
        if !device.appsLoaded { return "Your \(device.info?.deviceClass ?? "iPhone") is adding up each app's size…" }
        if device.isMeasuringMedia { return "What's using the space · measuring photos & media (\((device.media?.files ?? 0).formatted()) files)…" }
        if device.mediaWalkIncomplete { return "What's using the space · the \(device.info?.deviceClass ?? "iPhone") stopped responding, so this is incomplete. Press Refresh." }
        return "What's using the space"
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(segments) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.label).font(.system(size: 10.5))
                        Text(Int64(s.value).bytesString).font(.system(size: 10.5, weight: .medium)).monospacedDigit().opacity(0.8)
                    }
                    .fixedSize()
                }
                if segments.isEmpty {
                    Text(device.isReady ? "Sizing apps…" : "Unlock the iPhone to read its storage.").font(.system(size: 10.5)).opacity(0.6)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
        }
        .frame(height: 16)
    }

    private var sideStats: some View {
        VStack(alignment: .trailing, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Apps' Documents & Data")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let parts = ByteFormat.parts(device.totalDataSize)
                    Text(device.appsLoaded ? parts.number : "–")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(device.totalDataSize)))
                    if device.appsLoaded {
                        Text(parts.unit)
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .animation(.snappyUI, value: device.totalDataSize)
                .foregroundStyle(DevicePalette.data)
            }
            if device.isLoadingApps || device.isMeasuringMedia {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(device.isLoadingApps ? "Sizing apps…" : "Measuring media…")
                        .font(.system(size: 11)).foregroundStyle(.white.opacity(0.75))
                }
            } else {
                Button { device.loadDetails(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(color: .white.opacity(0.9), prominent: false))
                    .disabled(!device.isReady)
            }
        }
        .frame(minWidth: 170, alignment: .trailing)
    }

    private var background: some View {
        ZStack {
            Theme.heroGradient
            Circle().fill(DevicePalette.data.opacity(0.35)).frame(width: 260, height: 260).blur(radius: 70).offset(x: -220, y: 60)
            Circle().fill(DevicePalette.device.opacity(0.35)).frame(width: 240, height: 240).blur(radius: 70).offset(x: 260, y: -70)
            LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

// MARK: - Content

private struct DeviceContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let logs = device.crashLogs, logs.files > 0 {
                        CrashLogsCard(device: device, logs: logs)
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if let media = device.media, media.total > 0 {
                        MediaCard(device: device, media: media, measuring: device.isMeasuringMedia)
                            .transition(.opacity)
                    }
                    AppsSection(device: device)
                }
                .padding(16)
                .padding(.bottom, device.selectedAppIDs.isEmpty ? 0 : 70)
                .animation(.snappyUI, value: device.crashLogs)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { device.inspectedAppID = nil })

            if !device.selectedAppIDs.isEmpty {
                DeviceActionBar(device: device)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: device.selectedAppIDs.isEmpty)
        .onDeleteCommand { model.requestDeviceDelete(device.selectedApps, on: device) }
    }
}

private struct CrashLogsCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    let logs: CrashLogSummary
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "doc.text.magnifyingglass", color: FileCategory.caches.color, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(SafetyClassifier.iosCrashLogs.headline).font(.system(size: 13, weight: .semibold))
                    SafetyBadge(level: SafetyClassifier.iosCrashLogs.level)
                }
                Text("\(logs.files.formatted()) reports. \(SafetyClassifier.iosCrashLogs.explanation)")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Text(logs.bytes.bytesString)
                .font(.system(size: 13, weight: .semibold, design: .rounded)).monospacedDigit()
            Button("Show") { withAnimation(.snappyUI) { device.tab = .logs } }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.safe.color, prominent: false))
            Button("Clear…") { confirming = true }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.safe.color))
        }
        .card(padding: 12, tint: SafetyLevel.safe.color)
        .confirmationDialog("Delete \(logs.files) crash logs from \(device.displayName)?", isPresented: $confirming) {
            Button("Delete \(logs.bytes.bytesString) of Logs", role: .destructive) { model.clearCrashLogs(on: device) }
        } message: {
            Text("They're deleted on the device itself, so they can't be put back, but nothing needs them.")
        }
    }
}

private struct MediaCard: View {
    @ObservedObject var device: IOSDevice
    let media: DeviceMediaUsage
    let measuring: Bool

    private static let folders: [String: String] = [
        "photolibrary": "/PhotoData", "music": "/iTunes_Control", "books": "/Books",
        "downloads": "/Downloads", "recordings": "/Recordings",
    ]

    private func open(_ g: DeviceMediaGroup) {
        withAnimation(.snappyUI) {
            device.inspectedFile = nil
            if g.id == "photos" {
                device.tab = .photos
            } else {
                device.showInFiles(Self.folders[g.id] ?? "/")
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                IconTile(systemImage: "photo.on.rectangle.angled", color: DevicePalette.media, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Photos & media").font(.system(size: 13.5, weight: .semibold))
                    Text(measuring ? "Measuring… \(media.files.formatted()) files so far" : "\(media.files.formatted()) files in the iPhone's shared media area")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if measuring { ProgressView().controlSize(.small) }
                BytesText(bytes: media.total, font: .system(size: 15, weight: .bold, design: .rounded))
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(media.groups) { g in
                    Button { open(g) } label: { HStack(spacing: 8) {
                        Image(systemName: g.systemImage).font(.system(size: 12, weight: .semibold)).foregroundStyle(g.color).frame(width: 18)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(g.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(g.detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 4)
                        Text(g.size.bytesString).font(.system(size: 11.5, weight: .semibold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(SizeTier(g.size).color)
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.subtleFill))
                    .contentShape(Rectangle()) }
                    .buttonStyle(PressableButtonStyle())
                    .help(g.id == "photos" ? "Browse photos and videos" : "Browse this folder")
                }
            }
            Text("Click a group to look inside. Photos and videos are yours to judge: delete them in the Photos app so the library stays in sync. With iCloud Photos on, that removes them from your other devices too.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 12)
    }
}

private struct AppsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice

    var body: some View {
        let apps = device.sortedApps(filter: model.searchText)
        let maxTotal = device.apps.map(\.totalSize).max() ?? 1
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                IconTile(systemImage: "square.grid.3x3.fill", color: DevicePalette.app, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("Apps").font(.system(size: 13.5, weight: .semibold))
                        if device.appsLoaded {
                            Text("\(device.apps.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Theme.subtleFill))
                        }
                    }
                    Text("Documents & Data is what each app has stored: caches, downloads, offline content. Only deleting and reinstalling an app resets it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Picker("Sort", selection: $device.sort) {
                    ForEach(IOSDevice.AppSort.allCases) { Text("Sort: \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
            }

            if let err = device.appsError, !device.appsLoaded {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(SafetyLevel.caution.color)
                    .padding(.top, 10)
            }

            Divider().padding(.top, 10)
            columnHeader
            if !device.appsLoaded {
                if device.isLoadingApps {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Your \(device.info?.deviceClass ?? "iPhone") is adding up how much each app stores. This usually takes about 10 seconds.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 8).padding(.bottom, 4)
                }
                ForEach(0..<5, id: \.self) { _ in SkeletonRow() }
            } else if apps.isEmpty {
                Text(model.searchText.isEmpty ? "No apps installed from the App Store." : "No apps match “\(model.searchText)”.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(14)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(apps) { app in
                        DeviceAppRow(app: app, icon: device.icons[app.id], maxTotal: maxTotal,
                                     photoBytes: device.photoSource(forApp: app.id)?.bytes,
                                     sharesWith: device.sharingPartners(of: app).map(\.name),
                                     isChecked: device.selectedAppIDs.contains(app.id),
                                     isInspected: device.inspectedAppID == app.id,
                                     toggle: { toggle(app) },
                                     inspect: { device.inspectedAppID = app.id })
                        .contextMenu {
                            Button("Delete from iPhone…", role: .destructive) { model.requestDeviceDelete([app], on: device) }
                            Divider()
                            Button("Copy Bundle ID") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(app.id, forType: .string)
                            }
                        }
                    }
                }
                .animation(.spring(duration: 0.35), value: apps.map(\.id))
            }
        }
        .card(padding: 12)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Spacer()
            Text("App").frame(width: 70, alignment: .trailing)
            Text("Documents & Data").frame(width: 110, alignment: .trailing)
            Color.clear.frame(width: 64)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func toggle(_ app: IOSApp) {
        withAnimation(.snappyUI) {
            if device.selectedAppIDs.contains(app.id) { device.selectedAppIDs.remove(app.id) } else { device.selectedAppIDs.insert(app.id) }
        }
    }
}

private struct DeviceAppRow: View {
    let app: IOSApp
    let icon: NSImage?
    let maxTotal: Int64
    let photoBytes: Int64?
    let sharesWith: [String]
    let isChecked: Bool
    let isInspected: Bool
    let toggle: () -> Void
    let inspect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { CheckCircle(isOn: isChecked) }
                .buttonStyle(.plain)
                .help(isChecked ? "Deselect" : "Select to delete")
            AppIconView(image: icon, size: 30)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(app.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    if app.tip != nil {
                        Image(systemName: "lightbulb.fill").font(.system(size: 9.5)).foregroundStyle(Color(red: 0.98, green: 0.78, blue: 0.2))
                            .help("This app can free space without being deleted. Click the row to see how.")
                    }
                    if let photoBytes, photoBytes >= 20_000_000 {
                        Label(photoBytes.bytesString, systemImage: "photo.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(DevicePalette.media)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(DevicePalette.media.opacity(0.14)))
                            .help("This app saved \(photoBytes.bytesString) of photos and videos to your library. They stay if you delete the app.")
                    }
                    if !sharesWith.isEmpty {
                        Image(systemName: "link").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                            .help("Shares data with \(ListFormatter.localizedString(byJoining: sharesWith))")
                    }
                    if app.usesICloud {
                        Image(systemName: "icloud").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.secondary)
                            .help("Keeps data in iCloud too")
                    }
                }
                AppSizeBar(app: app.appSize, data: app.dataSize, maxTotal: maxTotal)
                    .frame(maxWidth: 260)
            }
            Spacer(minLength: 10)
            Text(app.appSize.bytesString)
                .font(.system(size: 11.5)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(app.dataSize.bytesString)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(SizeTier(app.dataSize).color == .secondary ? Color.primary : SizeTier(app.dataSize).color)
                .frame(width: 110, alignment: .trailing)
            SafetyBadge(level: app.assessment.level)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isInspected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: inspect)
        .onHover { hovering = $0 }
    }
}

struct AppSizeBar: View {
    let app: Int64
    let data: Int64
    let maxTotal: Int64

    var body: some View {
        GeometryReader { geo in
            let total = max(app + data, 1)
            let width = max(4, geo.size.width * CGFloat(Double(app + data) / Double(max(maxTotal, 1))))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.06))
                HStack(spacing: 0) {
                    Rectangle().fill(DevicePalette.app).frame(width: width * CGFloat(Double(app) / Double(total)))
                    Rectangle().fill(DevicePalette.data).frame(width: width * CGFloat(Double(data) / Double(total)))
                }
                .frame(width: width, alignment: .leading)
                .clipShape(Capsule())
            }
        }
        .frame(height: 5)
        .help("App \(app.bytesString) · Documents & Data \(data.bytesString)")
    }
}

struct AppIconView: View {
    let image: NSImage?
    var size: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).transition(.opacity)
            } else {
                shape.fill(LinearGradient(colors: [Color.primary.opacity(0.12), Color.primary.opacity(0.06)], startPoint: .top, endPoint: .bottom))
                    .overlay(Image(systemName: "app.dashed").font(.system(size: size * 0.45)).foregroundStyle(.tertiary))
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .animation(.easeOut(duration: 0.25), value: image != nil)
    }
}

private struct DeviceActionBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice

    var body: some View {
        let selected = device.selectedApps
        let size = selected.reduce(0) { $0 + $1.totalSize }
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selected.count) app\(selected.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(SafetyLevel.allCases, id: \.self) { l in
                        let c = selected.filter { $0.assessment.level == l }.count
                        if c > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: l.systemImage).font(.system(size: 9, weight: .bold))
                                Text("\(c)")
                            }
                            .font(.system(size: 10.5, weight: .medium)).foregroundStyle(l.color)
                        }
                    }
                }
            }
            Spacer()
            BytesText(bytes: size, font: .system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(SafetyLevel.safe.color)
            Button("Clear") { withAnimation(.snappyUI) { device.selectedAppIDs.removeAll() } }
                .buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Button {
                model.requestDeviceDelete(selected, on: device)
            } label: {
                Label("Delete from \(device.info?.deviceClass ?? "iPhone")…", systemImage: "trash")
            }
            .buttonStyle(PillButtonStyle(color: SafetyLevel.protected.color))
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Inspector

struct DeviceInspectorPane: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if let device = model.selectedDevice {
                DeviceInspectorContent(device: device)
            } else {
                EmptyState(systemImage: "iphone.slash", title: "No device", message: "Connect an iPhone or iPad with a cable.", tint: .secondary)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct DeviceInspectorContent: View {
    @ObservedObject var device: IOSDevice

    var body: some View {
        if device.tab == .backup {
            BackupInspector()
        } else if device.tab == .overview {
            if let app = device.inspectedApp {
                DeviceAppInspector(device: device, app: app).id(app.id)
            } else {
                DeviceOverviewInspector(device: device)
            }
        } else if let file = device.inspectedFile {
            DeviceFileInspector(device: device, file: file).id(file.id)
        } else {
            DeviceTabOverviewInspector(device: device)
        }
    }
}

private struct DeviceAppInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    let app: IOSApp

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [DevicePalette.data.opacity(0.25), DevicePalette.app.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    AppIconView(image: device.icons[app.id], size: 84)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                }
                .frame(height: 150)
                VStack(alignment: .leading, spacing: 4) {
                    Text(app.name).font(.system(size: 16, weight: .semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        Image(systemName: device.systemImage)
                        Text("On \(device.displayName)")
                        Text("·")
                        Text(app.totalSize.bytesString).fontWeight(.semibold).foregroundStyle(SizeTier(app.totalSize).color)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                sizes
                AppDataMap(device: device, app: app)
                SafetyCard(assessment: app.assessment)
                if let tip = app.tip {
                    note(icon: "lightbulb.fill", color: Color(red: 0.98, green: 0.72, blue: 0.15), title: "Free space without deleting", text: tip)
                }
                if app.appSize > 20_000_000 {
                    note(icon: "icloud.and.arrow.down", color: DevicePalette.app, title: "Keep the data, drop the app",
                         text: "On the iPhone, Settings ▸ General ▸ iPhone Storage ▸ \(app.name) ▸ Offload App frees \(app.appSize.bytesString) and keeps your data. The icon stays; tap it to download the app again.")
                }
                DetailsGrid(rows: [("Bundle ID", app.id)] + (app.version.map { [("Version", $0)] } ?? []) + [("Files", app.fileSharing ? "Visible in Finder and Files" : "Private to the app")])
                Button(role: .destructive) { model.requestDeviceDelete([app], on: device) } label: {
                    Label("Delete from \(device.info?.deviceClass ?? "iPhone")…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SafetyLevel.protected.color)
                .controlSize(.large)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sizes: some View {
        VStack(spacing: 8) {
            row("App", app.appSize, DevicePalette.app)
            row("Documents & Data", app.dataSize, DevicePalette.data)
            Divider()
            HStack {
                Text("Freed by deleting").font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text(app.totalSize.bytesString).font(.system(size: 12.5, weight: .bold, design: .rounded)).monospacedDigit()
            }
        }
        .card(padding: 12)
    }

    private func row(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.system(size: 11.5))
            Spacer()
            Text(bytes.bytesString).font(.system(size: 11.5, weight: .medium)).monospacedDigit()
        }
    }

    private func note(icon: String, color: Color, title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            Text(text).font(.system(size: 11.5)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(color.opacity(0.09)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(color.opacity(0.25)))
    }
}

private struct DeviceOverviewInspector: View {
    @ObservedObject var device: IOSDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cleaning an iPhone").font(.system(size: 14, weight: .semibold))
                section("square.grid.3x3.fill", DevicePalette.app, "What DiskScout can do",
                        "See every app's size and how much it has stored, delete apps you don't need, and clear crash logs. Browse photos, videos, files and logs in the other tabs, and copy anything to your Mac. Click an app to see what deleting it means.")
                section("internaldrive.fill", DevicePalette.data, "Why apps grow",
                        "Documents & Data is caches, downloads and offline content. iPhone apps keep it in private storage that no Mac app can open, so the only reset is deleting the app and reinstalling it from the App Store.")
                section("exclamationmark.triangle.fill", SafetyLevel.caution.color, "There's no Trash on iPhone",
                        "Deleting an app on the iPhone is permanent. Apps that keep your account online come back after you sign in; chats, wallets and authenticator codes may not.")
                section("icloud.fill", DevicePalette.device, "What stays after deleting an app",
                        "iOS deletes the app's own files. What's left lives elsewhere: its iCloud data (Settings ▸ your name ▸ iCloud ▸ Manage Storage), saved passwords, and photos or files it saved to Photos or Files.")
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(color.opacity(0.08)))
    }
}

// MARK: - Status bar

struct DeviceStatusText: View {
    @ObservedObject var device: IOSDevice
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.systemImage).foregroundStyle(DevicePalette.device)
            Text(device.displayName)
            if device.appsLoaded {
                Text("·").foregroundStyle(.tertiary)
                Text("\(device.apps.count) apps")
                Text("·").foregroundStyle(.tertiary)
                Text("\(device.totalDataSize.bytesString) of app data")
            }
            if let info = device.info {
                Text("·").foregroundStyle(.tertiary)
                Text("\(info.free.bytesString) free").fontWeight(.semibold)
            }
            let selectedCount = device.tab == .overview ? device.selectedAppIDs.count : device.selectedFileIDs.count
            if selectedCount > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(selectedCount) selected")
            }
        }
        .monospacedDigit()
    }
}

/// Toolbar trash button while a device is shown (it has to observe the device to enable itself).
struct DeviceTrashToolbarButton: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    var body: some View {
        Button { model.requestDeviceDelete(device.selectedApps, on: device) } label: { Label("Delete from iPhone", systemImage: "trash") }
            .disabled(device.tab != .overview || device.selectedAppIDs.isEmpty)
            .help("Delete the selected apps from \(device.displayName) (⌘⌫)")
    }
}

// MARK: - Sidebar row

struct DeviceSidebarRow: View {
    @ObservedObject var device: IOSDevice

    var body: some View {
        HStack(spacing: 9) {
            IconTile(systemImage: device.systemImage, color: DevicePalette.device, size: 22)
            Text(device.displayName).font(.system(size: 13)).lineLimit(1)
            if device.link.isWiFi {
                Image(systemName: "wifi").font(.system(size: 9)).foregroundStyle(.secondary).help("Connected over Wi-Fi")
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.vertical, 1)
    }

    @ViewBuilder
    private var trailing: some View {
        switch device.phase {
        case .ready:
            if let info = device.info {
                Text(ByteFormat.string(info.used))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(DevicePalette.fullness(info.usedFraction))
                    .help("\(info.used.bytesString) used · \(info.free.bytesString) free of \(info.capacity.bytesString)")
            }
        case .connecting:
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        case .needsTrust:
            Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary)
                .help("Unlock the iPhone and tap Trust")
        case .failed(let m):
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(SafetyLevel.caution.color)
                .help(m)
        }
    }
}

// MARK: - Delete sheet

/// Confirms deleting apps from a connected device. Unlike the Mac's Trash there's no Undo, so the
/// sheet says so plainly and Caution apps need an explicit acknowledgement.
struct DeviceDeleteSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: DeviceDeletePlan

    @State private var acknowledgedCaution = false
    @State private var phase: Phase = .review
    @State private var progress: (done: Int, current: String) = (0, "")
    @State private var outcome: DeviceUninstallOutcome?

    enum Phase { case review, working, done }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .review: reviewBody
            case .working: workingBody
            case .done: doneBody
            }
        }
        .frame(width: 560)
        .frame(minHeight: 380, maxHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var deviceName: String { plan.device.displayName }

    private var reviewBody: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(SafetyLevel.protected.color.opacity(0.12)).frame(width: 46, height: 46)
                    Image(systemName: plan.device.systemImage).font(.system(size: 20)).foregroundStyle(SafetyLevel.protected.color)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Delete \(plan.apps.count) app\(plan.apps.count == 1 ? "" : "s") from \(deviceName)?")
                        .font(.system(size: 16, weight: .bold))
                    HStack(spacing: 8) {
                        Text("Frees \(plan.totalSize.bytesString)").font(.system(size: 12, weight: .semibold)).foregroundStyle(SafetyLevel.safe.color)
                        ForEach([SafetyLevel.review, .caution], id: \.self) { l in
                            if plan.count(l) > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: l.systemImage).font(.system(size: 9, weight: .bold))
                                    Text("\(plan.count(l)) \(l.shortTitle.lowercased())")
                                }
                                .font(.system(size: 11)).foregroundStyle(l.color)
                            }
                        }
                    }
                }
                Spacer()
            }
            .padding(16)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.apps) { app in
                        DeleteCandidateRow(app: app, icon: plan.device.icons[app.id],
                                           stays: plan.device.leftovers(of: app, alsoDeleting: Set(plan.apps.map(\.id))))
                    }
                }
                .padding(16)
            }
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                if plan.hasCaution {
                    Toggle(isOn: $acknowledgedCaution) {
                        Text("I understand the Caution apps may hold data that exists only on this \(plan.device.info?.deviceClass ?? "iPhone") and won't come back.")
                            .font(.system(size: 11.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .toggleStyle(.checkbox)
                }
                HStack {
                    Label("This can't be undone. Reinstall from the App Store anytime.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(SafetyLevel.caution.color)
                    Spacer()
                    Button("Cancel") { model.dismissPlan() }
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(.bordered)
                    Button {
                        Task { await run() }
                    } label: {
                        Label("Delete from \(plan.device.info?.deviceClass ?? "iPhone")", systemImage: "trash")
                    }
                    // Deliberately no Return shortcut: this can't be undone, so it takes a click.
                    .buttonStyle(.borderedProminent)
                    .tint(SafetyLevel.protected.color)
                    .disabled(plan.hasCaution && !acknowledgedCaution)
                }
            }
            .padding(16)
        }
    }

    private var workingBody: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8).frame(width: 90, height: 90)
                Circle()
                    .trim(from: 0, to: CGFloat(progress.done) / CGFloat(max(plan.apps.count, 1)))
                    .stroke(SafetyLevel.safe.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 90, height: 90)
                    .animation(.snappyUI, value: progress.done)
                Image(systemName: plan.device.systemImage).font(.system(size: 26)).foregroundStyle(.secondary)
            }
            Text(progress.current.isEmpty ? "Checking \(deviceName)…" : "Deleting \(progress.current)…").font(.system(size: 15, weight: .semibold))
            Text("\(progress.done) of \(plan.apps.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text("Keep the \(plan.device.info?.deviceClass ?? "iPhone") connected.").font(.system(size: 11)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(30)
    }

    private var doneBody: some View {
        VStack(spacing: 14) {
            Spacer()
            SuccessCheck(color: (outcome?.failed.isEmpty ?? true) ? SafetyLevel.safe.color : SafetyLevel.caution.color)
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(doneTitle).font(.system(size: 18, weight: .bold))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Freed")
                    Text((outcome?.freed ?? 0).bytesString).fontWeight(.bold).foregroundStyle(SafetyLevel.safe.color)
                }
                .font(.system(size: 14))
            }
            if let failed = outcome?.failed, !failed.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(failed) { f in
                            HStack(alignment: .top, spacing: 8) {
                                AppIconView(image: plan.device.icons[f.app.id], size: 22)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(f.app.name).font(.system(size: 11.5, weight: .semibold))
                                    Text(f.reason).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .background(RoundedRectangle(cornerRadius: 10).fill(SafetyLevel.caution.color.opacity(0.1)))
                .padding(.horizontal, 20)
            }
            Spacer()
            Button("Done") { finish() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle())
                .padding(.bottom, 18)
        }
        .padding(20)
    }

    private var doneTitle: String {
        guard let outcome else { return "Done" }
        if !outcome.failed.isEmpty { return "Finished with \(outcome.failed.count) problem\(outcome.failed.count == 1 ? "" : "s")" }
        return "Deleted \(outcome.removed.count) app\(outcome.removed.count == 1 ? "" : "s")"
    }

    private func finish() {
        if let outcome { model.finishDeviceDelete(outcome, on: plan.device) } else { model.dismissPlan() }
    }

    private func run() async {
        withAnimation(.snappyUI) { phase = .working }
        let result = await plan.device.uninstall(plan.apps) { done, name in
            progress = (done, name)
        }
        outcome = result
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { phase = .done }
        if result.failed.isEmpty {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if phase == .done { finish() }
        }
    }
}

private struct DeleteCandidateRow: View {
    let app: IOSApp
    let icon: NSImage?
    let stays: [String]
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                AppIconView(image: icon, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(app.assessment.headline).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SafetyBadge(level: app.assessment.level)
                Text(app.totalSize.bytesString).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 76, alignment: .trailing)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            if expanded || app.assessment.level == .caution {
                Text(app.assessment.explanation)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
            if expanded, let tip = app.tip {
                Label(tip, systemImage: "lightbulb.fill")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            }
            if !stays.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stays after deleting:").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SafetyLevel.caution.color)
                    ForEach(stays, id: \.self) { line in
                        Label(line, systemImage: "arrow.turn.down.right")
                            .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 38)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(app.assessment.level.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(app.assessment.level.color.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappyUI) { expanded.toggle() } }
    }
}

// MARK: - Where an app's data lives

/// Every place an app keeps data on (or off) the iPhone, and whether deleting the app removes it.
/// Apple doesn't let Mac apps open App Store apps' private folders, so sizes are shown where iOS
/// reports them and the rest is described.
private struct AppDataMap: View {
    @ObservedObject var device: IOSDevice
    let app: IOSApp
    @State private var docs: DeviceDirStat?

    private var docsDomain: DeviceFileDomain { .appDocuments(app.id) }

    var body: some View {
        let partners = device.sharingPartners(of: app)
        let ownGroups = app.groups.filter { device.appsSharing($0, besides: app.id).isEmpty }
        VStack(alignment: .leading, spacing: 10) {
            Text("Where \(app.name)'s data lives").font(.system(size: 12.5, weight: .semibold))

            row(icon: "lock.fill", color: DevicePalette.data, title: "Private storage", value: app.dataSize.bytesString,
                text: "Caches, downloads and settings. Only iOS can open this folder.", goes: true)

            if app.fileSharing {
                row(icon: "doc.on.doc.fill", color: DevicePalette.app, title: "Shared Documents",
                    value: docs.map { "\($0.files.formatted()) files · \($0.size.bytesString)" } ?? "…",
                    text: "Files the app lets Finder and the Files app see.", goes: true,
                    action: ("Browse", { device.showInFiles("/Documents", domain: docsDomain) }))
            }

            if let photos = device.photoSource(forApp: app.id), photos.bytes > 0 {
                row(icon: "photo.fill", color: DevicePalette.media, title: "Saved to Photos",
                    value: "\(photos.items.formatted()) · \(photos.bytes.bytesString)",
                    text: "Photos and videos it added to your library.", goes: false,
                    action: ("Show", { device.photoSourceFilter = app.id; device.selectedFileIDs = []; device.tab = .photos }))
            } else if app.canSaveToPhotos && device.photoSourcesState == .loading {
                row(icon: "photo", color: DevicePalette.media, title: "Saved to Photos", value: "checking…",
                    text: "Looking for photos and videos it added to your library.", goes: false)
            }

            if !partners.isEmpty {
                row(icon: "link", color: DevicePalette.device, title: "Shared with \(ListFormatter.localizedString(byJoining: partners.map(\.name)))",
                    value: nil,
                    text: "Storage these apps share. It stays until the last of them is deleted. iOS doesn't report its size.",
                    goes: false)
            }
            if !ownGroups.isEmpty {
                row(icon: "square.stack.3d.up.fill", color: .secondary,
                    title: "\(ownGroups.count) shared area\(ownGroups.count == 1 ? "" : "s") for its widgets & extensions", value: nil,
                    text: "No other app on this iPhone uses them, so they go with it.", goes: true)
            }
            if app.usesICloud {
                row(icon: "icloud.fill", color: Color(red: 0.27, green: 0.62, blue: 1.0), title: "iCloud", value: nil,
                    text: "Data it syncs to iCloud. Manage it in Settings ▸ your name ▸ iCloud ▸ Manage Storage.", goes: false)
            }
            row(icon: "key.fill", color: Color(red: 0.98, green: 0.72, blue: 0.15), title: "Saved sign-ins", value: nil,
                text: "Logins in the Keychain stay on the iPhone and come back if you reinstall.", goes: false)
        }
        .card(padding: 12)
        .task(id: app.id) {
            guard app.fileSharing else { return }
            if device.docStats[docsDomain.key] == nil { await device.loadDocStats(docsDomain) }
            docs = device.docStats[docsDomain.key]?["/Documents"] ?? DeviceDirStat()
        }
    }

    private func row(icon: String, color: Color, title: String, value: String?, text: String, goes: Bool,
                     action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(color).frame(width: 16).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 11.5, weight: .semibold)).lineLimit(2)
                    Spacer(minLength: 4)
                    if let value { Text(value).font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.secondary) }
                }
                Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(goes ? "Deleted with the app" : "Stays after deleting")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(goes ? SafetyLevel.safe.color : SafetyLevel.caution.color)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill((goes ? SafetyLevel.safe.color : SafetyLevel.caution.color).opacity(0.13)))
                    if let action {
                        Button(action.0, action: action.1).buttonStyle(.link).font(.system(size: 10.5, weight: .semibold))
                    }
                }
            }
        }
    }
}
