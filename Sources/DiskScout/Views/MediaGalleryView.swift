import SwiftUI
import AppKit

/// A flat gallery of every photo, video and audio file under one folder, however deeply nested.
/// Opened from the inspector's "Show Media" action in its own window.
struct MediaGalleryView: View {
    @EnvironmentObject var model: AppModel
    let root: URL

    @StateObject private var finder = MediaFinder()
    @State private var filter: MediaKind? = nil
    @State private var sort: MediaSort = .largest
    @State private var layout: GalleryLayout = .grid
    @State private var search = ""
    @State private var tileSize: CGFloat = 150
    @State private var selection: Set<URL> = []
    @Namespace private var chipNamespace

    enum MediaSort: String, CaseIterable, Identifiable {
        case largest = "Largest first"
        case newest = "Newest first"
        case oldest = "Oldest first"
        case name = "Name"
        case folder = "Folder"
        var id: String { rawValue }
    }

    enum GalleryLayout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }
        var systemImage: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
    }

    private var visible: [MediaItem] {
        var items = finder.items
        if let filter { items = items.filter { $0.kind == filter } }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { items = items.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.relativeFolder.localizedCaseInsensitiveContains(q) } }
        switch sort {
        case .largest: items.sort { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
        case .newest: items.sort { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
        case .oldest: items.sort { ($0.modified ?? .distantFuture) < ($1.modified ?? .distantFuture) }
        case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .folder: items.sort { $0.relativeFolder != $1.relativeFolder ? $0.relativeFolder.localizedStandardCompare($1.relativeFolder) == .orderedAscending : $0.size > $1.size }
        }
        return items
    }

    private var selectedItems: [MediaItem] { finder.items.filter { selection.contains($0.url) } }
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
        .navigationTitle("Media in \(root.lastPathComponent)")
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { quickLookSelection(); return .handled }
        .onKeyPress(.escape) { selection = []; return .handled }
        .onKeyPress(characters: .init(charactersIn: "aA")) { press in
            guard press.modifiers.contains(.command) else { return .ignored }
            selection = Set(visible.map(\.url)); return .handled
        }
        .onDeleteCommand { trashSelection() }
        .onAppear { finder.start(root: root, options: model.settings.scanOptions) }
        .onDisappear { finder.cancel() }
        .onChange(of: model.mediaTrashPlan?.id) { _, id in
            if id == nil {
                finder.pruneMissing()
                let remaining = Set(finder.items.map(\.url))
                selection = selection.intersection(remaining)
            }
        }
        .onChange(of: selection) { _, sel in
            if QuickLookController.shared.isVisible, !sel.isEmpty {
                QuickLookController.shared.update(visible.filter { sel.contains($0.url) }.map(\.url))
            }
        }
        .sheet(item: $model.mediaTrashPlan) { plan in
            ReviewSheet(plan: plan).environmentObject(model)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast { ToastView(toast: toast).padding(.bottom, 52) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "photo.on.rectangle.angled", color: FileCategory.photos.color, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Media in \(root.lastPathComponent)").font(.system(size: 15, weight: .bold)).lineLimit(1)
                HStack(spacing: 6) {
                    Text(root.path).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 6) {
                    if finder.isScanning {
                        ProgressView().controlSize(.small)
                        Text("Looking through \(finder.foldersVisited.formatted()) folders…")
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
                    finder.start(root: root, options: model.settings.scanOptions)
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

            Spacer(minLength: 8)

            TextField("Filter by name or folder", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 190)

            Picker("Sort", selection: $sort) {
                ForEach(MediaSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().fixedSize()

            Picker("Layout", selection: $layout.animation(.snappyUI)) {
                ForEach(GalleryLayout.allCases) { Image(systemName: $0.systemImage).tag($0) }
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
        if finder.truncated || finder.unreadable {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(SafetyLevel.review.color)
                if finder.truncated {
                    Text("Showing the first \(MediaFinder.maxItems.formatted()) items. Open a subfolder to see the rest.")
                }
                if finder.unreadable {
                    Text("Some folders couldn't be read.")
                    Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }.buttonStyle(.link)
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
                           message: "DiskScout looked inside every subfolder of \(root.lastPathComponent) and found no photos, videos or audio files.",
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

    private func grid(_ items: [MediaItem]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileSize, maximum: tileSize * 1.35), spacing: 12)], spacing: 14) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    MediaTile(item: item, size: tileSize, selected: selection.contains(item.url)) {
                        select(item, in: items)
                    } preview: {
                        selection = [item.url]
                        QuickLookController.shared.preview(items.map(\.url), startingAt: index)
                    }
                    .contextMenu { contextMenu(for: item, in: items, index: index) }
                }
            }
            .padding(16)
            .animation(.snappyUI, value: tileSize)
        }
        .background(Color.clear.contentShape(Rectangle()).onTapGesture { selection = [] })
    }

    private func list(_ items: [MediaItem]) -> some View {
        List(selection: $selection) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                MediaListRow(item: item, rootName: root.lastPathComponent) {
                    selection = [item.url]
                    QuickLookController.shared.preview(items.map(\.url), startingAt: index)
                }
                .tag(item.url)
                .contextMenu { contextMenu(for: item, in: items, index: index) }
            }
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private func contextMenu(for item: MediaItem, in items: [MediaItem], index: Int) -> some View {
        let targets = selection.contains(item.url) && selection.count > 1 ? items.filter { selection.contains($0.url) } : [item]
        Button(targets.count > 1 ? "Quick Look \(targets.count) Items" : "Quick Look") {
            if targets.count > 1 { QuickLookController.shared.preview(targets.map(\.url)) }
            else { QuickLookController.shared.preview(items.map(\.url), startingAt: index) }
        }
        Button("Show in Finder") { model.reveal(targets.map(\.url)) }
        Button("Open") { for t in targets.prefix(10) { NSWorkspace.shared.open(t.url) } }
        Button("Copy Path") { model.copyPath(item.url) }
        Divider()
        Button(targets.count > 1 ? "Move \(targets.count) Items to Trash…" : "Move to Trash…", role: .destructive) {
            model.requestTrash(media: targets)
        }
        .disabled(targets.allSatisfy { !$0.assessment.canDelete })
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if selection.isEmpty {
                Text("Click to select · double-click or Space to preview · ⌘A selects everything shown")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
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
            Button { model.reveal(selectedItems.map(\.url)) } label: { Label("Show in Finder", systemImage: "folder") }
                .disabled(selection.isEmpty)
            Button(role: .destructive) { trashSelection() } label: {
                Label(selection.count > 1 ? "Move \(selection.count) to Trash…" : "Move to Trash…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .tint(SafetyLevel.protected.color)
            .disabled(selection.isEmpty)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    // MARK: Actions

    private func select(_ item: MediaItem, in items: [MediaItem]) {
        if Modifiers.commandDown {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
        } else if Modifiers.shiftDown, let anchor = selection.first,
                  let a = items.firstIndex(where: { $0.url == anchor }), let b = items.firstIndex(where: { $0.url == item.url }) {
            selection.formUnion(items[min(a, b)...max(a, b)].map(\.url))
        } else {
            selection = [item.url]
        }
    }

    private func quickLookSelection() {
        let items = visible
        let sel = items.filter { selection.contains($0.url) }
        if sel.count == 1, let idx = items.firstIndex(of: sel[0]) {
            QuickLookController.shared.toggle(items.map(\.url), startingAt: idx)
        } else if !sel.isEmpty {
            QuickLookController.shared.toggle(sel.map(\.url))
        } else if !items.isEmpty {
            QuickLookController.shared.toggle(items.map(\.url))
        }
    }

    private func trashSelection() {
        let items = selectedItems
        guard !items.isEmpty else { return }
        model.requestTrash(media: items)
    }
}

// MARK: - Chip

private struct KindChip: View {
    let title: String
    let systemImage: String
    let color: Color
    let count: Int
    let size: Int64
    let selected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
                Text(count.formatted())
                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.25) : color.opacity(0.15)))
                    .contentTransition(.numericText())
            }
            .foregroundStyle(selected ? Color.white : color)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background {
                if selected {
                    Capsule().fill(color).matchedGeometryEffect(id: "chip", in: namespace)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(size > 0 ? "\(count.formatted()) items · \(size.bytesString)" : "\(count.formatted()) items")
        .animation(.snappyUI, value: count)
    }
}

// MARK: - Tile

private struct MediaTile: View {
    let item: MediaItem
    let size: CGFloat
    let selected: Bool
    let select: () -> Void
    let preview: () -> Void

    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(item.kind.color.opacity(item.kind == .audio ? 0.16 : 0.08))
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: item.kind == .audio ? .fit : .fill)
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(item.kind == .audio ? size * 0.18 : 0)
                        .transition(.opacity)
                } else {
                    Image(systemName: item.kind.systemImage)
                        .font(.system(size: size * 0.28, weight: .medium))
                        .foregroundStyle(item.kind.color.opacity(0.5))
                }
                if item.kind == .videos {
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
                    Image(systemName: item.kind.systemImage).font(.system(size: 8, weight: .bold))
                    Text(item.url.pathExtension.uppercased()).font(.system(size: 8.5, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(item.kind.color.opacity(0.9)))
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
                    if !item.relativeFolder.isEmpty {
                        Text("·")
                        Text(item.relativeFolder).lineLimit(1).truncationMode(.head)
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
        .help(item.url.path)
        .task(id: "\(item.url.path)@\(Int(size))") {
            image = ThumbnailLoader.shared.cached(item.url, size: size)
            if image == nil {
                let img = await ThumbnailLoader.shared.thumbnail(for: item.url, size: size)
                withAnimation(.easeOut(duration: 0.25)) { image = img }
            }
        }
    }
}

// MARK: - List row

private struct MediaListRow: View {
    let item: MediaItem
    let rootName: String
    let preview: () -> Void
    @State private var image: NSImage?

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(item.kind.color.opacity(0.12))
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 5))
                } else {
                    Image(systemName: item.kind.systemImage).font(.system(size: 12)).foregroundStyle(item.kind.color)
                }
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.relativeFolder.isEmpty ? rootName : "\(rootName)/\(item.relativeFolder)")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: item.kind.systemImage).font(.system(size: 8, weight: .bold))
                Text(item.kind.rawValue).font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(item.kind.color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(item.kind.color.opacity(0.14)))
            if let m = item.modified {
                Text(DateFormat.relativeString(m)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 90, alignment: .trailing)
            }
            Text(item.size.bytesString)
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(SizeTier(item.size).color)
                .frame(width: 76, alignment: .trailing)
            HoverButton(systemImage: "eye", help: "Quick Look", action: preview)
        }
        .padding(.vertical, 2)
        .task(id: item.url) {
            image = ThumbnailLoader.shared.cached(item.url, size: 64)
            if image == nil { image = await ThumbnailLoader.shared.thumbnail(for: item.url, size: 64) }
        }
    }
}
