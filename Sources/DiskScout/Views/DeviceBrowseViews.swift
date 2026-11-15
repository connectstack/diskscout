import SwiftUI
import AppKit

// Photos & Videos, Files and Logs tabs for a connected iPhone or iPad.

// MARK: - Tab bar

struct DeviceTabBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(DeviceTab.allCases) { tab in button(tab) }
            }
            .padding(3)
            .background(Capsule().fill(Theme.subtleFill))
            Spacer(minLength: 0)
            if device.isMeasuringMedia && device.tab != .overview && device.tab != .logs {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading the iPhone's files… \((device.media?.files ?? 0).formatted())")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func count(_ tab: DeviceTab) -> String? {
        switch tab {
        case .overview: return nil
        case .photos: return device.cameraRollLoaded ? device.cameraRoll.filter { $0.kind.isVisualMedia }.count.formatted() : nil
        case .files: return nil
        case .logs: return device.crashLogs.map { $0.files.formatted() }
        case .backup: return nil
        }
    }

    private func button(_ tab: DeviceTab) -> some View {
        let selected = device.tab == tab
        return Button {
            withAnimation(.snappyUI) {
                device.tab = tab
                model.searchText = ""
                device.selectedFileIDs = []
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: tab.systemImage).font(.system(size: 11, weight: .semibold))
                Text(tab.rawValue).font(.system(size: 12, weight: selected ? .semibold : .medium))
                if let c = count(tab) {
                    Text(c).font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                        .opacity(0.75)
                }
            }
            .fixedSize()
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [DevicePalette.device, DevicePalette.device.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: DevicePalette.device.opacity(0.35), radius: 5, y: 2)
                        .matchedGeometryEffect(id: "device-tab", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Shared pieces

/// A device photo or video thumbnail that loads itself (and reports a video's length).
struct DeviceThumb: View {
    let device: IOSDevice
    let file: DeviceFile
    var contentMode: ContentMode = .fill
    var onDuration: ((Double) -> Void)? = nil
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: contentMode).transition(.opacity)
            } else {
                LinearGradient(colors: [file.kind.color.opacity(0.28), file.kind.color.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: file.kind.systemImage).font(.system(size: 18)).foregroundStyle(file.kind.color.opacity(0.8))
            }
        }
        .task(id: file.id) {
            if image == nil { image = device.thumbnails.cached(file) }
            if image == nil, file.kind.isVisualMedia {
                let img = await device.thumbnail(for: file)
                withAnimation(.easeOut(duration: 0.2)) { image = img }
            }
            if let d = device.thumbnails.durations[file.id] { onDuration?(d) }
        }
    }
}

struct DeviceTransferPill: View {
    @EnvironmentObject var model: AppModel
    let transfer: DeviceTransfer
    var body: some View {
        HStack(spacing: 10) {
            ProgressView(value: transfer.fraction).frame(width: 110)
            VStack(alignment: .leading, spacing: 0) {
                Text(transfer.title).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                Text("\(transfer.done.bytesString) of \(transfer.total.bytesString)").font(.system(size: 10.5)).foregroundStyle(.secondary).monospacedDigit()
            }
            Button { model.cancelDeviceTransfer() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain).help("Stop copying")
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(Capsule().fill(.regularMaterial))
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
        .frame(maxWidth: 420)
        .padding(.bottom, 16)
    }
}

private func durationString(_ s: Double) -> String {
    let t = Int(s.rounded())
    return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
}

private struct SelectionBar: View {
    let count: Int
    let size: Int64
    let noun: String
    let clear: () -> Void
    let copy: () -> Void
    var delete: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 14) {
            Text("\(count) \(noun)\(count == 1 ? "" : "s") selected").font(.system(size: 12.5, weight: .semibold))
            Spacer()
            BytesText(bytes: size, font: .system(size: 20, weight: .bold, design: .rounded))
            Button("Clear", action: clear).buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Button(action: copy) { Label("Copy to Mac…", systemImage: "square.and.arrow.down") }
                .buttonStyle(PillButtonStyle(color: DevicePalette.device))
            if let delete {
                Button(action: delete) { Label("Delete…", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(color: SafetyLevel.protected.color))
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

// MARK: - Photos & Videos

struct DevicePhotosTab: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", videos = "Videos", photos = "Photos", screenshots = "Screenshots"
        var id: String { rawValue }
    }
    enum Order: String, CaseIterable, Identifiable {
        case largest = "Largest first", newest = "Newest first", oldest = "Oldest first"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    @AppStorage("devicePhotosFilter") private var filter: Filter = .all
    @AppStorage("devicePhotosOrder") private var order: Order = .largest

    /// Live Photo videos: a .MOV next to a photo with the same name.
    private var livePhotoVideos: Set<String> {
        let stills = Set(device.cameraRoll.filter { $0.kind == .photo || $0.kind == .screenshot }.map { $0.parentPath + "/" + $0.baseName.uppercased() })
        return Set(device.cameraRoll.filter { $0.kind == .video && stills.contains($0.parentPath + "/" + $0.baseName.uppercased()) }.map(\.id))
    }

    private func items(live: Set<String>) -> [DeviceFile] {
        var list = device.cameraRoll.filter { $0.kind.isVisualMedia }
        switch filter {
        case .all: break
        case .videos: list = list.filter { $0.kind == .video && !live.contains($0.id) }
        case .photos: list = list.filter { $0.kind == .photo }
        case .screenshots: list = list.filter { $0.kind == .screenshot }
        }
        if let source = device.photoSourceFilter { list = list.filter { device.photoSourceID(of: $0) == source } }
        if !model.searchText.isEmpty {
            let q = model.searchText.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) || $0.parentPath.lowercased().contains(q) }
        }
        switch order {
        case .largest: list.sort { $0.size > $1.size }
        case .newest: list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: list.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        }
        return list
    }

    var body: some View {
        let live = livePhotoVideos
        let list = items(live: live)
        ZStack(alignment: .bottom) {
            if !device.cameraRollLoaded {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Finding photos and videos on \(device.displayName)…").font(.callout).foregroundStyle(.secondary)
                    Text("\((device.media?.files ?? 0).formatted()) files checked").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header(live: live, shown: list)
                        if list.isEmpty {
                            Text(model.searchText.isEmpty ? "Nothing here." : "Nothing matches “\(model.searchText)”.")
                                .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 190), spacing: 10)], spacing: 10) {
                            ForEach(list) { f in
                                DevicePhotoTile(device: device, file: f, isLive: live.contains(f.id),
                                                isSelected: device.selectedFileIDs.contains(f.id),
                                                isInspected: device.inspectedFile?.id == f.id)
                            }
                        }
                    }
                    .padding(16)
                    .padding(.bottom, device.selectedFileIDs.isEmpty ? 0 : 70)
                }
            }
            if !device.selectedFileIDs.isEmpty {
                let selected = device.cameraRoll.filter { device.selectedFileIDs.contains($0.id) }
                SelectionBar(count: selected.count, size: selected.reduce(0) { $0 + $1.size }, noun: "item",
                             clear: { withAnimation(.snappyUI) { device.selectedFileIDs = [] } },
                             copy: { model.copyToMac(selected, from: device) })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: device.selectedFileIDs.isEmpty)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if let f = device.inspectedFile { model.quickLook(f, on: device) }
            return .handled
        }
    }

    private func header(live: Set<String>, shown: [DeviceFile]) -> some View {
        let media = device.cameraRoll.filter { $0.kind.isVisualMedia }
        let videos = media.filter { $0.kind == .video && !live.contains($0.id) }
        let videoBytes = videos.reduce(0) { $0 + $1.size }
        let total = media.reduce(0) { $0 + $1.size }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "photo.on.rectangle.angled", color: DevicePalette.media, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    if let id = device.photoSourceFilter, let src = device.photoSources.first(where: { $0.id == id }) {
                        Text("\(src.items.formatted()) items from \(src.name) · \(src.bytes.bytesString)").font(.system(size: 14, weight: .semibold))
                    } else {
                        Text("\(media.count.formatted()) photos and videos · \(total.bytesString)").font(.system(size: 14, weight: .semibold))
                    }
                    Group {
                        if let id = device.photoSourceFilter, let src = device.photoSources.first(where: { $0.id == id }), total > 0 {
                            Text("That's \(max(1, Int((Double(src.bytes) / Double(total) * 100).rounded())))% of the \(total.bytesString) of photos and videos on this iPhone.")
                        } else {
                            Text(total > 0 && videoBytes > total / 3
                                 ? "\(videos.count.formatted()) videos take \(videoBytes.bytesString), \(Int((Double(videoBytes) / Double(total) * 100).rounded()))% of it. Sort by size to find the big ones."
                                 : "Sort by size to find what takes the most space.")
                        }
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                SafetyBadge(level: .review)
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Picker("Order", selection: $order) {
                    ForEach(Order.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.menu).labelsHidden().fixedSize()
                Spacer()
                Text("\(shown.count.formatted()) shown · \(shown.reduce(0) { $0 + $1.size }.bytesString)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            PhotoSourcesStrip(device: device)
            Label("Delete photos in the Photos app on the iPhone so albums, edits and iCloud stay in sync. Copy anything you want to keep to your Mac first.", systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card(padding: 14)
    }
}

/// "Saved by": which app put the photos and videos into the library. Click one to filter the grid.
struct PhotoSourcesStrip: View {
    @ObservedObject var device: IOSDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Saved by").font(.system(size: 11.5, weight: .semibold))
                switch device.photoSourcesState {
                case .loading, .idle:
                    ProgressView().controlSize(.mini)
                    Text("Reading which app saved each item…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .unavailable(let why):
                    Text(why).font(.system(size: 11)).foregroundStyle(.secondary)
                case .ready:
                    if let id = device.photoSourceFilter, let src = device.photoSources.first(where: { $0.id == id }) {
                        Text("· \(src.detail)").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    } else {
                        Text("· click one to see only what it added").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }
            if device.photoSourcesState == .ready {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(device.photoSources) { src in chip(src) }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func chip(_ src: PhotoSource) -> some View {
        let selected = device.photoSourceFilter == src.id
        return Button {
            withAnimation(.snappyUI) {
                device.photoSourceFilter = selected ? nil : src.id
                device.selectedFileIDs = []
            }
        } label: {
            HStack(spacing: 5) {
                if src.isApp, device.apps.contains(where: { $0.id == src.id }) {
                    AppIconView(image: device.icons[src.id], size: 16)
                } else {
                    Image(systemName: src.systemImage).font(.system(size: 10, weight: .semibold))
                }
                Text(src.name).font(.system(size: 11.5, weight: .medium))
                Text(src.bytes.bytesString).font(.system(size: 10.5, weight: .semibold)).monospacedDigit().opacity(0.75)
            }
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? DevicePalette.device : Theme.subtleFill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(src.items.formatted()) item\(src.items == 1 ? "" : "s") · \(src.bytes.bytesString) — \(src.detail)")
    }
}

private struct DevicePhotoTile: View {
    @EnvironmentObject var model: AppModel
    let device: IOSDevice
    let file: DeviceFile
    let isLive: Bool
    let isSelected: Bool
    let isInspected: Bool
    @State private var duration: Double?
    @State private var hovering = false

    var body: some View {
        // A fixed square that the thumbnail fills and is clipped to, whatever its aspect ratio.
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { DeviceThumb(device: device, file: file, onDuration: { duration = $0 }) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .bottom) {
            HStack(spacing: 4) {
                if file.kind == .video {
                    Image(systemName: isLive ? "livephoto" : "play.fill").font(.system(size: 9, weight: .bold))
                    if let duration, !isLive { Text(durationString(duration)) }
                } else if file.kind == .screenshot {
                    Image(systemName: "camera.viewfinder").font(.system(size: 9, weight: .bold))
                }
                Spacer(minLength: 2)
                Text(file.size.bytesString).fontWeight(.semibold)
            }
            .font(.system(size: 10.5)).monospacedDigit()
            .foregroundStyle(.white)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom))
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous))
        }
        .overlay(alignment: .topLeading) {
            if isSelected || hovering {
                Button { toggle() } label: { CheckCircle(isOn: isSelected, color: DevicePalette.device) }
                    .buttonStyle(.plain).padding(6)
                    .shadow(color: .black.opacity(0.3), radius: 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if file.size >= 500_000_000 {
                Text(SizeTier(file.size) == .huge ? "HUGE" : "BIG")
                    .font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(SizeTier(file.size).color))
                    .padding(6)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isInspected ? Color.accentColor : (isSelected ? DevicePalette.device : Color.primary.opacity(0.08)), lineWidth: isInspected || isSelected ? 2.5 : 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { model.quickLook(file, on: device) }
        .onTapGesture {
            if Modifiers.commandDown { toggle() } else { device.inspectedFile = file }
        }
        .contextMenu {
            Button("Quick Look") { model.quickLook(file, on: device) }
            Button("Copy to Mac…") { model.copyToMac([file], from: device) }
            Button("Show in Files") { device.showInFiles(file.parentPath, select: file) }
        }
        .help("\(file.name) · \(file.size.bytesString)\(file.date.map { " · " + DateFormat.string($0) } ?? "")")
    }

    private func toggle() {
        withAnimation(.snappyUI) {
            if device.selectedFileIDs.contains(file.id) { device.selectedFileIDs.remove(file.id) } else { device.selectedFileIDs.insert(file.id) }
        }
    }
}

// MARK: - Files

struct DeviceFilesTab: View {
    enum Order: String, CaseIterable, Identifiable {
        case size = "Size", name = "Name", date = "Date"
        var id: String { rawValue }
    }

    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    @State private var items: [DeviceFile] = []
    @State private var loadedPath: String?
    @State private var error: String?
    @AppStorage("deviceFilesOrder") private var order: Order = .size

    private var sorted: [DeviceFile] {
        var list = items
        if !model.searchText.isEmpty {
            let q = model.searchText.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) }
        }
        switch order {
        case .size: list.sort { device.size(of: $0) > device.size(of: $1) }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .date: list.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        }
        return list
    }

    var body: some View {
        let list = sorted
        let maxSize = max(list.map { device.size(of: $0) }.max() ?? 1, 1)
        VStack(spacing: 0) {
            pathBar
            Divider()
            if loadedPath != locationKey && error == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error {
                EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't open this folder", message: error,
                           tint: SafetyLevel.caution.color, action: ("Try Again", { Task { await load() } }))
            } else if list.isEmpty {
                EmptyState(systemImage: "folder", title: model.searchText.isEmpty ? "Empty folder" : "No matches",
                           message: model.searchText.isEmpty ? "There's nothing in this folder." : "Nothing here matches “\(model.searchText)”.", tint: .secondary)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(list) { f in
                            DeviceFileRow(device: device, file: f, size: device.size(of: f), maxSize: maxSize,
                                          fileCount: f.isDirectory ? device.stat(of: f.path, in: f.domain)?.files : nil,
                                          isInspected: device.inspectedFile?.id == f.id)
                                .onTapGesture(count: 2) { open(f) }
                                .onTapGesture { device.inspectedFile = f }
                                .contextMenu {
                                    if f.isDirectory {
                                        Button("Open") { open(f) }
                                        if f.domain == .media {
                                            Button("Show Media Inside") { model.showMedia(on: device, path: f.path) }
                                        }
                                    } else {
                                        Button("Quick Look") { model.quickLook(f, on: device) }
                                        Button("Copy to Mac…") { model.copyToMac([f], from: device) }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .task(id: locationKey) { await load() }
        .task(id: device.filesDomain.key) { await device.loadDocStats(device.filesDomain) }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if let f = device.inspectedFile, !f.isDirectory { model.quickLook(f, on: device) }
            return .handled
        }
    }

    /// Which folder of which area is showing (media, or one app's shared Documents).
    private var locationKey: String { device.filesDomain.key + "|" + device.filesPath }

    private var domainApp: IOSApp? { device.filesDomain.appID.flatMap { id in device.apps.first { $0.id == id } } }

    private func load() async {
        let key = locationKey
        let path = device.filesPath, domain = device.filesDomain
        error = nil
        do {
            let result = try await device.listing(path, in: domain)
            guard key == locationKey else { return }
            items = result
            loadedPath = key
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func open(_ f: DeviceFile) {
        if f.isDirectory {
            device.inspectedFile = nil
            model.searchText = ""
            device.filesPath = f.path
        } else {
            model.quickLook(f, on: device)
        }
    }

    private var pathBar: some View {
        let root = device.filesDomain.rootPath
        let relative = device.filesPath.hasPrefix(root) ? String(device.filesPath.dropFirst(root.count)) : device.filesPath
        let parts = relative.split(separator: "/").map(String.init)
        let rootBase = root == "/" ? "" : root
        return HStack(spacing: 4) {
            Button { goUp() } label: { Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold)).frame(width: 22, height: 22) }
                .buttonStyle(.plain)
                .disabled(parts.isEmpty)
                .help("Enclosing folder")
            locationMenu
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    crumb(domainApp.map { "\($0.name) · Documents" } ?? device.displayName, path: root, icon: domainApp == nil ? device.systemImage : "doc.on.doc", isLast: parts.isEmpty)
                    ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                        crumb(part, path: rootBase + "/" + parts[...i].joined(separator: "/"), icon: nil, isLast: i == parts.count - 1)
                    }
                }
            }
            Spacer(minLength: 8)
            if let stat = device.stat(of: device.filesPath, in: device.filesDomain) {
                Text("\(stat.files.formatted()) files · \(stat.size.bytesString)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            }
            if device.filesDomain == .media {
                Button { model.showMedia(on: device, path: device.filesPath) } label: {
                    Label("Show Media", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered).controlSize(.small)
                .help("Every photo, video and audio file in this folder and all its subfolders (⇧⌘M)")
            }
            Picker("Sort", selection: $order) {
                ForEach(Order.allCases) { Text("Sort: \($0.rawValue)").tag($0) }
            }
            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }

    private func crumb(_ title: String, path: String, icon: String?, isLast: Bool) -> some View {
        Button {
            device.inspectedFile = nil
            device.filesPath = path
        } label: {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon).font(.system(size: 10)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
            .foregroundStyle(isLast ? Color.primary : Color.secondary)
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(isLast ? Theme.subtleFill : .clear))
        }
        .buttonStyle(.plain)
    }

    private func goUp() {
        let p = (device.filesPath as NSString).deletingLastPathComponent
        device.inspectedFile = nil
        device.filesPath = p.count < device.filesDomain.rootPath.count ? device.filesDomain.rootPath : (p.isEmpty ? "/" : p)
    }

    /// Switches between the iPhone's media area and the shared Documents of apps that allow it.
    private var locationMenu: some View {
        Menu {
            Button { switchTo(.media) } label: { Label("\(device.displayName) media", systemImage: device.systemImage) }
            if !device.fileSharingApps.isEmpty {
                Section("Apps that share files") {
                    ForEach(device.fileSharingApps) { app in
                        Button { switchTo(.appDocuments(app.id)) } label: { Label(app.name, systemImage: "doc.on.doc") }
                    }
                }
            }
        } label: {
            Image(systemName: "rectangle.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Browse the iPhone's media, or the Documents folder of an app that shares files")
    }

    private func switchTo(_ domain: DeviceFileDomain) {
        device.inspectedFile = nil
        model.searchText = ""
        device.filesDomain = domain
        device.filesPath = domain.rootPath
    }
}

private struct DeviceFileRow: View {
    let device: IOSDevice
    let file: DeviceFile
    let size: Int64
    let maxSize: Int64
    let fileCount: Int?
    let isInspected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if file.kind.isVisualMedia {
                    DeviceThumb(device: device, file: file)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(file.kind.color.opacity(0.18))
                        Image(systemName: file.kind.systemImage).font(.system(size: 13, weight: .semibold)).foregroundStyle(file.kind.color)
                    }
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name).font(.system(size: 12.5, weight: file.isDirectory ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                SizeBar(fraction: Double(size) / Double(maxSize), color: file.isDirectory ? DevicePalette.device : file.kind.color, height: 4)
                    .frame(maxWidth: 260)
            }
            Spacer(minLength: 10)
            if let fileCount {
                Text("\(fileCount.formatted()) files").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 90, alignment: .trailing)
            }
            Text(file.date.map { DateFormat.relativeString($0) } ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
            Text(size > 0 || !file.isDirectory ? size.bytesString : "—")
                .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(SizeTier(size).color == .secondary ? Color.primary : SizeTier(size).color)
                .frame(width: 80, alignment: .trailing)
            SafetyBadge(level: file.assessment.level, compact: true)
                .frame(width: 26)
            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .opacity(file.isDirectory ? 1 : 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isInspected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Logs

struct DeviceLogsTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    @State private var typeFilter: String?
    @State private var confirmDelete: [DeviceFile] = []
    @State private var confirmClearAll = false

    private var parsed: [(file: DeviceFile, info: DeviceLogInfo)] {
        device.logFiles.map { ($0, DeviceLogInfo.parse($0)) }
    }

    var body: some View {
        let all = parsed
        let types = Dictionary(grouping: all, by: { $0.info.type }).map { ($0.key, $0.value.count) }.sorted { $0.1 > $1.1 }
        var shown = all
        if let typeFilter { shown = shown.filter { $0.info.type == typeFilter } }
        if !model.searchText.isEmpty {
            let q = model.searchText.lowercased()
            shown = shown.filter { $0.info.process.lowercased().contains(q) || $0.info.type.lowercased().contains(q) || $0.file.name.lowercased().contains(q) }
        }
        return ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header(types: types, total: all.count)
                    if shown.isEmpty {
                        Text(all.isEmpty ? "No crash or diagnostic logs on \(device.displayName)." : "No logs match.")
                            .font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(40)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(shown, id: \.file.id) { item in
                                LogRow(file: item.file, info: item.info,
                                       isChecked: device.selectedFileIDs.contains(item.file.id),
                                       isInspected: device.inspectedFile?.id == item.file.id,
                                       toggle: { toggle(item.file) })
                                    .onTapGesture(count: 2) { model.quickLook(item.file, on: device) }
                                    .onTapGesture { device.inspectedFile = item.file }
                                    .contextMenu {
                                        Button("Quick Look") { model.quickLook(item.file, on: device) }
                                        Button("Copy to Mac…") { model.copyToMac([item.file], from: device) }
                                        Divider()
                                        Button("Delete…", role: .destructive) { confirmDelete = [item.file] }
                                    }
                            }
                        }
                        .card(padding: 8)
                    }
                }
                .padding(16)
                .padding(.bottom, device.selectedFileIDs.isEmpty ? 0 : 70)
            }
            if !device.selectedFileIDs.isEmpty {
                let selected = device.logFiles.filter { device.selectedFileIDs.contains($0.id) }
                SelectionBar(count: selected.count, size: selected.reduce(0) { $0 + $1.size }, noun: "log",
                             clear: { withAnimation(.snappyUI) { device.selectedFileIDs = [] } },
                             copy: { model.copyToMac(selected, from: device) },
                             delete: { confirmDelete = selected })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: device.selectedFileIDs.isEmpty)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            if let f = device.inspectedFile { model.quickLook(f, on: device) }
            return .handled
        }
        .confirmationDialog("Delete \(confirmDelete.count) log\(confirmDelete.count == 1 ? "" : "s") from \(device.displayName)?",
                            isPresented: Binding(get: { !confirmDelete.isEmpty }, set: { if !$0 { confirmDelete = [] } })) {
            Button("Delete \(confirmDelete.reduce(0) { $0 + $1.size }.bytesString) of Logs", role: .destructive) {
                model.deleteLogs(confirmDelete, on: device)
                confirmDelete = []
            }
        } message: {
            Text("They're deleted on the device itself, so they can't be put back, but nothing needs them.")
        }
        .confirmationDialog("Delete all \(device.logFiles.count) logs from \(device.displayName)?", isPresented: $confirmClearAll) {
            Button("Delete All Logs", role: .destructive) { model.clearCrashLogs(on: device) }
        } message: {
            Text("They're deleted on the device itself, so they can't be put back, but nothing needs them.")
        }
    }

    private func header(types: [(String, Int)], total: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                IconTile(systemImage: "doc.text.magnifyingglass", color: FileCategory.caches.color, size: 30)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("\(total.formatted()) crash & diagnostic logs · \((device.crashLogs?.bytes ?? 0).bytesString)").font(.system(size: 14, weight: .semibold))
                        SafetyBadge(level: .safe)
                    }
                    Text("Reports iOS writes when an app crashes, hangs, runs out of memory or uses too much battery. Double-click one to read it. The newest are at the top.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Delete All…") { confirmClearAll = true }
                    .buttonStyle(PillButtonStyle(color: SafetyLevel.safe.color))
                    .disabled(total == 0)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    chip("All", count: total, selected: typeFilter == nil) { typeFilter = nil }
                    ForEach(types, id: \.0) { t in
                        chip(t.0, count: t.1, selected: typeFilter == t.0) { typeFilter = typeFilter == t.0 ? nil : t.0 }
                    }
                }
            }
        }
        .card(padding: 14)
    }

    private func chip(_ title: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappyUI) { action() } }) {
            HStack(spacing: 4) {
                Text(title)
                Text("\(count)").fontWeight(.semibold).opacity(0.7)
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(Capsule().fill(selected ? DevicePalette.device : Theme.subtleFill))
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ f: DeviceFile) {
        withAnimation(.snappyUI) {
            if device.selectedFileIDs.contains(f.id) { device.selectedFileIDs.remove(f.id) } else { device.selectedFileIDs.insert(f.id) }
        }
    }
}

private struct LogRow: View {
    let file: DeviceFile
    let info: DeviceLogInfo
    let isChecked: Bool
    let isInspected: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var typeColor: Color {
        switch info.type {
        case "Crash": return SafetyLevel.protected.color
        case "Low-memory event": return SafetyLevel.caution.color
        case "Stopped for CPU use", "System restart": return SafetyLevel.caution.color
        case "Heavy CPU use", "Heavy disk writes", "Too many wake-ups", "Non-fatal fault": return Color(red: 0.98, green: 0.78, blue: 0.2)
        default: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { CheckCircle(isOn: isChecked) }.buttonStyle(.plain)
            Image(systemName: info.type == "Crash" ? "exclamationmark.octagon.fill" : "doc.text.fill")
                .font(.system(size: 14)).foregroundStyle(typeColor).frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.process).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                Text(info.type).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Text(info.date.map { DateFormat.string($0) } ?? "")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            Text(file.size.bytesString)
                .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isInspected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.04) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Inspector

struct DeviceFileInspector: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    let file: DeviceFile
    @State private var duration: Double?
    @State private var confirmingDelete = false

    var body: some View {
        let log = file.domain == .crashLogs ? DeviceLogInfo.parse(file) : nil
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [file.kind.color.opacity(0.25), file.kind.color.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if file.kind.isVisualMedia {
                        DeviceThumb(device: device, file: file, contentMode: .fit, onDuration: { duration = $0 })
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                            .padding(12)
                    } else {
                        Image(systemName: file.kind.systemImage).font(.system(size: 54)).foregroundStyle(file.kind.color)
                    }
                }
                .frame(height: 200)
                VStack(alignment: .leading, spacing: 4) {
                    Text(log?.process ?? file.name).font(.system(size: 16, weight: .semibold)).lineLimit(3)
                    HStack(spacing: 6) {
                        Image(systemName: device.systemImage)
                        Text(log?.type ?? kindName)
                        Text("·")
                        Text(device.size(of: file).bytesString).fontWeight(.semibold).foregroundStyle(SizeTier(device.size(of: file)).color)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                SafetyCard(assessment: file.assessment)
                DetailsGrid(rows: details(log: log))
                InspectorActions(actions: actions)
                if file.domain == .crashLogs {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        Label("Delete from \(device.info?.deviceClass ?? "iPhone")…", systemImage: "trash").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SafetyLevel.protected.color)
                    .controlSize(.large)
                    .confirmationDialog("Delete this log from \(device.displayName)?", isPresented: $confirmingDelete) {
                        Button("Delete Log", role: .destructive) { model.deleteLogs([file], on: device) }
                    } message: {
                        Text("It's deleted on the device itself, so it can't be put back, but nothing needs it.")
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var kindName: String {
        switch file.kind {
        case .folder: return "Folder"
        case .photo: return "Photo"
        case .screenshot: return "Screenshot"
        case .video: return "Video"
        case .audio: return "Audio"
        case .document: return "Document"
        case .log: return "Log"
        case .database: return "Library data"
        case .photoEdit: return "Photo edit"
        case .other: return "File"
        }
    }

    private func details(log: DeviceLogInfo?) -> [(String, String)] {
        let whereText: String
        switch file.domain {
        case .crashLogs: whereText = "Crash logs" + (file.parentPath == "/" ? "" : file.parentPath)
        case .appDocuments(let id): whereText = (device.apps.first { $0.id == id }?.name ?? id) + " ▸ " + file.parentPath.dropFirst()
        case .media: whereText = file.parentPath
        }
        var rows: [(String, String)] = [("Name", file.name), ("Where", whereText)]
        if let d = log?.date ?? file.date { rows.append((file.domain == .crashLogs ? "Written" : "Created", DateFormat.string(d))) }
        if let duration { rows.append(("Length", durationString(duration))) }
        if file.isDirectory, let stat = device.dirStats[file.path] { rows.append(("Contains", "\(stat.files.formatted()) files")) }
        rows.append(("Size", device.size(of: file).bytesString))
        return rows
    }

    private var actions: [InspectorActions.Action] {
        if file.isDirectory {
            return [
                .init(title: "Open", systemImage: "folder") { device.showInFiles(file.path, domain: file.domain) },
            ] + (file.domain == .media ? [.init(title: "Show Media", systemImage: "photo.on.rectangle.angled", tint: FileCategory.photos.color) { model.showMedia(on: device, path: file.path) }] : [])
        }
        var a: [InspectorActions.Action] = [
            .init(title: "Quick Look", systemImage: "eye") { model.quickLook(file, on: device) },
            .init(title: "Copy to Mac…", systemImage: "square.and.arrow.down") { model.copyToMac([file], from: device) },
        ]
        if device.tab != .files && file.domain == .media {
            a.append(.init(title: "Show in Files", systemImage: "folder") { device.showInFiles(file.parentPath, select: file) })
        }
        return a
    }
}

struct DeviceTabOverviewInspector: View {
    @ObservedObject var device: IOSDevice

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(device.tab.rawValue).font(.system(size: 14, weight: .semibold))
                Text(text).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Click an item to see it here. Double-click or press Space to open it in Quick Look.")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var text: String {
        switch device.tab {
        case .photos: return "Every photo and video in the camera roll, read straight from the iPhone. Copy what you want to keep to your Mac, then delete it in the Photos app so the library and iCloud stay in sync."
        case .files: return "The part of the iPhone a Mac is allowed to see: the camera roll, the Photos library's own files, books, music and downloads. Apps' private storage isn't visible to any Mac app; the Overview tab shows how big each app is instead."
        case .logs: return "Crash and diagnostic reports. They're safe to delete: iOS doesn't need them after they're written."
        case .overview, .backup: return ""
        }
    }
}
