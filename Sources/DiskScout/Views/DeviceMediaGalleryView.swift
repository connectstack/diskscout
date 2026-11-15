import SwiftUI
import AppKit

/// Every photo, video and audio file inside one iPhone folder, however deeply nested — the
/// device counterpart of `MediaGalleryView`. Read-only: items can be previewed and copied to
/// the Mac; photos are deleted in the Photos app so its library stays consistent.
struct DeviceMediaGalleryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var devices: DeviceMonitor
    let request: DeviceMediaRequest

    var body: some View {
        Group {
            if let device = devices.device(id: request.deviceID), device.isReady {
                DeviceMediaGalleryContent(device: device, request: request)
            } else {
                EmptyState(systemImage: "cable.connector.slash", title: "iPhone disconnected",
                           message: "Plug it back in and unlock it to see the media in \(request.folderName).", tint: .secondary)
                    .frame(minWidth: 760, minHeight: 480)
            }
        }
        .navigationTitle("Media in \(request.folderName)")
        .background(NonRestorableWindow())
    }
}

/// Keeps macOS from reopening this window at the next launch: the device may not be connected
/// then, and a fresh walk at launch would compete with the device view's own loading.
private struct NonRestorableWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.isRestorable = false }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isRestorable = false
    }
}

private struct DeviceMediaGalleryContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var device: IOSDevice
    let request: DeviceMediaRequest

    @StateObject private var finder = DeviceMediaFinder()
    @State private var filter: MediaKind? = nil
    @State private var sort: MediaGalleryView.MediaSort = .largest
    @State private var layout: MediaGalleryView.GalleryLayout = .grid
    @State private var search = ""
    @State private var tileSize: CGFloat = 150
    @State private var selection: Set<String> = []
    @Namespace private var chipNamespace

    private func relativeFolder(_ f: DeviceFile) -> String {
        let parent = f.parentPath
        let root = request.path == "/" ? "" : request.path
        guard parent.hasPrefix(root) else { return parent }
        return String(parent.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var visible: [DeviceFile] {
        var items = finder.items
        if let filter { items = items.filter { $0.mediaKind == filter } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.parentPath.localizedCaseInsensitiveContains(q) } }
        switch sort {
        case .largest: items.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        case .newest: items.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
        case .oldest: items.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .folder: items.sort { $0.parentPath != $1.parentPath ? $0.parentPath.localizedStandardCompare($1.parentPath) == .orderedAscending : $0.size > $1.size }
        }
        return items
    }

    private var selectedItems: [DeviceFile] { finder.items.filter { selection.contains($0.id) } }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            toolbar
            Divider()
            banners
            content
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { quickLookSelection(); return .handled }
        .onKeyPress(.escape) { selection = []; return .handled }
        .onKeyPress(characters: .init(charactersIn: "aA")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(visible.map(\.id)); return .handled
        }
        .onAppear { finder.start(device: device, root: request.path) }
        .onDisappear { finder.cancel() }
        .overlay(alignment: .bottom) {
            if let transfer = model.deviceTransfer {
                DeviceTransferPill(transfer: transfer).padding(.bottom, 44)
            } else if let toast = model.toast {
                ToastView(toast: toast).padding(.bottom, 52)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "photo.on.rectangle.angled", color: FileCategory.photos.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Media in \(request.folderName)").font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack(spacing: 5) {
                    Image(systemName: device.systemImage)
                    Text("\(device.displayName) · \(request.path)").lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if finder.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Looking through \(finder.foldersVisited.formatted()) folders on the iPhone…")
                    } else {
                        Text("\(finder.items.count.formatted()) item\(finder.items.count == 1 ? "" : "s") in \(finder.foldersVisited.formatted()) folder\(finder.foldersVisited == 1 ? "" : "s")")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .contentTransition(.numericText())
                BytesText(bytes: finder.totalSize, font: .system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(SizeTier(finder.totalSize).color)
            }
            if finder.isScanning {
                Button("Stop") { finder.cancel() }.buttonStyle(.bordered).controlSize(.small)
            } else {
                HoverButton(systemImage: "arrow.clockwise", help: "Look again") {
                    selection = []
                    finder.start(device: device, root: request.path)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 4) {
                KindChip(title: "All", systemImage: "square.grid.2x2.fill", color: .accentColor,
                         count: finder.items.count, size: finder.totalSize, selected: filter == nil, namespace: chipNamespace) {
                    withAnimation(.snappyUI) { filter = nil }
                }
                ForEach(MediaKind.allCases) { kind in
                    KindChip(title: kind.rawValue, systemImage: kind.systemImage, color: kind.color,
                             count: finder.count(of: kind), size: finder.size(of: kind), selected: filter == kind, namespace: chipNamespace) {
                        withAnimation(.snappyUI) { filter = filter == kind ? nil : kind }
                    }
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.subtleFill))
            .fixedSize()

            Spacer(minLength: 8)

            TextField("Filter by name or folder", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 110, maxWidth: 190)

            Picker("Sort", selection: $sort) {
                ForEach(MediaGalleryView.MediaSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()

            Picker("Layout", selection: $layout.animation(.snappyUI)) {
                ForEach(MediaGalleryView.GalleryLayout.allCases) { Image(systemName: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()

            if layout == .grid {
                HStack(spacing: 4) {
                    Image(systemName: "photo").font(.system(size: 9)).foregroundStyle(.secondary)
                    Slider(value: $tileSize, in: 96...260).frame(width: 90)
                    Image(systemName: "photo").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .help("Thumbnail size")
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    @ViewBuilder
    private var banners: some View {
        if finder.truncated || finder.error != nil {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SafetyLevel.review.color)
                if let e = finder.error {
                    Text(e)
                } else {
                    Text("Showing the first \(DeviceMediaFinder.maxItems.formatted()) items. Open a subfolder to see the rest.")
                }
                Spacer()
            }
            .font(.system(size: 11.5))
            .padding(.horizontal, 16).padding(.vertical, 7)
            .background(SafetyLevel.review.color.opacity(0.08))
            Divider()
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let items = visible
        if items.isEmpty {
            if finder.isScanning {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("Looking for photos, videos and audio…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if finder.items.isEmpty {
                EmptyState(systemImage: "photo.on.rectangle.angled", title: "No media in here",
                           message: "DiskScout looked inside every subfolder of \(request.folderName) on \(device.displayName) and found no photos, videos or audio files.",
                           tint: FileCategory.photos.color)
            } else {
                EmptyState(systemImage: "line.3.horizontal.decrease.circle", title: "Nothing matches",
                           message: "No \(filter?.rawValue.lowercased() ?? "media") match the current filter.", tint: .secondary,
                           action: ("Clear filters", { withAnimation(.snappyUI) { filter = nil; search = "" } }))
            }
        } else {
            switch layout {
            case .grid: grid(items)
            case .list: list(items)
            }
        }
    }

    private func grid(_ items: [DeviceFile]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 12)], spacing: 14) {
                ForEach(items) { item in
                    DeviceMediaTile(device: device, item: item, folder: relativeFolder(item), size: tileSize, selected: selection.contains(item.id)) {
                        select(item, in: items)
                    } preview: {
                        selection = [item.id]
                        model.quickLook([item], on: device)
                    }
                    .contextMenu { contextMenu(for: item, in: items) }
                }
            }
            .padding(16)
            .animation(.snappyUI, value: tileSize)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] })
    }

    private func list(_ items: [DeviceFile]) -> some View {
        List(selection: $selection) {
            ForEach(items) { item in
                DeviceMediaListRow(device: device, item: item, folder: relativeFolder(item), rootName: request.folderName) {
                    selection = [item.id]
                    model.quickLook([item], on: device)
                }
                .tag(item.id)
                .contextMenu { contextMenu(for: item, in: items) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func contextMenu(for item: DeviceFile, in items: [DeviceFile]) -> some View {
        let targets = selection.contains(item.id) && selection.count > 1 ? items.filter { selection.contains($0.id) } : [item]
        Button(targets.count > 1 ? "Quick Look \(targets.count) Items" : "Quick Look") { model.quickLook(targets, on: device) }
        Button(targets.count > 1 ? "Copy \(targets.count) Items to Mac…" : "Copy to Mac…") { model.copyToMac(targets, from: device) }
        Button("Show in Files") { showInFiles(item) }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if selection.isEmpty {
                Text("Click to select · double-click or Space to preview · ⌘A selects all")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .help("Photos and videos are deleted in the Photos app on the iPhone, so its library and iCloud stay in sync.")
            } else {
                HStack(spacing: 6) {
                    Text("\(selection.count.formatted()) selected").font(.system(size: 12, weight: .semibold))
                    Text("·").foregroundStyle(.secondary)
                    BytesText(bytes: selectedSize, font: .system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(SizeTier(selectedSize).color)
                }
                .contentTransition(.numericText())
            }
            Spacer()
            Button { quickLookSelection() } label: { Label("Quick Look", systemImage: "eye") }
                .disabled(selection.isEmpty)
            Button { if let f = selectedItems.first { showInFiles(f) } } label: { Label("Show in Files", systemImage: "folder") }
                .disabled(selection.count != 1)
            Button { model.copyToMac(selectedItems, from: device) } label: {
                Label(selection.count > 1 ? "Copy \(selection.count) to Mac…" : "Copy to Mac…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .tint(DevicePalette.device)
            .disabled(selection.isEmpty || model.deviceTransfer != nil)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Actions

    private func select(_ item: DeviceFile, in items: [DeviceFile]) {
        if Modifiers.commandDown {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else if Modifiers.shiftDown, let anchor = selection.first,
                  let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selection.formUnion(items[min(a, b)...max(a, b)].map(\.id))
        } else {
            selection = [item.id]
        }
    }

    private func quickLookSelection() {
        let sel = visible.filter { selection.contains($0.id) }
        if !sel.isEmpty { model.quickLook(sel, on: device) }
    }

    private func showInFiles(_ item: DeviceFile) {
        model.select(device: device)
        device.showInFiles(item.parentPath, select: item)
        openWindow(id: "main")
    }
}

// MARK: - Tile

private struct DeviceMediaTile: View {
    let device: IOSDevice
    let item: DeviceFile
    let folder: String
    let size: CGFloat
    let selected: Bool
    let select: () -> Void
    let preview: () -> Void

    @State private var hovering = false
    @State private var duration: Double?

    private var kind: MediaKind { item.mediaKind ?? .photos }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(kind.color.opacity(kind == .audio ? 0.16 : 0.08))
                if kind == .audio {
                    Image(systemName: kind.systemImage)
                        .font(.system(size: size * 0.28, weight: .medium))
                        .foregroundStyle(kind.color.opacity(0.6))
                } else {
                    Color.clear
                        .frame(width: size, height: size)
                        .overlay { DeviceThumb(device: device, file: item, onDuration: { duration = $0 }) }
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                if kind == .videos {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: size * 0.24))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .scaleEffect(hovering ? 1.08 : 1)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Image(systemName: kind.systemImage).font(.system(size: 8, weight: .bold))
                    Text(item.ext.uppercased()).font(.system(size: 8.5, weight: .bold))
                    if let duration {
                        Text("· " + Self.durationString(duration)).font(.system(size: 8.5, weight: .bold)).monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(kind.color.opacity(0.9)))
                .padding(6)
            }
            .overlay(alignment: .topTrailing) {
                if hovering {
                    Button(action: preview) {
                        Image(systemName: "eye.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    .help("Quick Look")
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(hovering ? 0.12 : 0.06), lineWidth: selected ? 3 : 1)
            )
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.08), radius: hovering ? 10 : 4, y: hovering ? 6 : 2)
            .scaleEffect(hovering && !selected ? 1.025 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 4) {
                    Text(item.size.bytesString).fontWeight(.semibold).foregroundStyle(SizeTier(item.size).color)
                    if !folder.isEmpty {
                        Text("·")
                        Text(folder).lineLimit(1).truncationMode(.head)
                    }
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .frame(width: size, alignment: .leading)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Color.accentColor.opacity(0.12) : .clear))
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: preview)
        .onTapGesture(perform: select)
        .onHover { h in withAnimation(.spring(duration: 0.25)) { hovering = h } }
        .help("\(item.path) · \(item.size.bytesString)")
    }

    static func durationString(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - List row

private struct DeviceMediaListRow: View {
    let device: IOSDevice
    let item: DeviceFile
    let folder: String
    let rootName: String
    let preview: () -> Void

    private var kind: MediaKind { item.mediaKind ?? .photos }

    var body: some View {
        HStack(spacing: 10) {
            DeviceThumb(device: device, file: item)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(folder.isEmpty ? rootName : "\(rootName)/\(folder)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: kind.systemImage).font(.system(size: 8, weight: .bold))
                Text(kind.rawValue).font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(kind.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(kind.color.opacity(0.14)))
            if let d = item.date {
                Text(DateFormat.relativeString(d)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            Text(item.size.bytesString)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(SizeTier(item.size).color)
                .frame(width: 76, alignment: .trailing)
            SafetyBadge(level: item.assessment.level, compact: true)
            HoverButton(systemImage: "eye", help: "Quick Look", action: preview)
        }
        .padding(.vertical, 2)
    }
}
