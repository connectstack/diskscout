import SwiftUI
import AppKit

struct BrowseView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(engine: engine, onReveal: { model.reveal([$0]) })
            Divider()
            columnHeader
            Divider()
            list
        }
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading)
            Text("Safety").frame(width: 84, alignment: .leading)
            Text("Share").frame(width: 120, alignment: .leading)
            Text("Size").frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 14, height: 1)
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 5)
        .background(Theme.subtleFill.opacity(0.6))
    }

    @ViewBuilder
    private var list: some View {
        let items = model.currentChildren
        if let current = engine.current {
            if items.isEmpty {
                if !model.searchText.isEmpty {
                    EmptyState(systemImage: "magnifyingglass", title: "No matches", message: "Nothing in “\(current.name)” matches “\(model.searchText)”.", tint: .secondary)
                } else if current.unreadable {
                    EmptyState(systemImage: "lock.fill", title: "macOS blocked this folder",
                               message: "DiskScout needs Full Disk Access to read inside “\(current.name)”.",
                               tint: SafetyLevel.caution.color,
                               action: ("Open Privacy Settings", { model.openFullDiskAccessSettings() }))
                } else {
                    EmptyState(systemImage: "tray", title: "Empty folder", message: "There's nothing inside “\(current.name)”.", tint: .secondary)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(items) { node in
                                FileRow(
                                    node: node,
                                    parentSize: current.size,
                                    isSelected: model.selection.contains(node.id),
                                    onSelect: { model.select(node, extend: Modifiers.commandDown, range: items, shift: Modifiers.shiftDown) },
                                    onOpen: { open(node) }
                                )
                                .id(node.id)
                                .contextMenu { NodeContextMenu(nodes: contextNodes(for: node, in: items), open: { open(node) }) }
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                    }
                    .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() })
                    .focusable()
                    .focusEffectDisabled()
                    .onKeyPress(.space) { model.quickLookSelection(); return .handled }
                    .onKeyPress(.return) {
                        if let n = model.selectedNodes(in: items).first, model.selection.count == 1 { open(n) }
                        return .handled
                    }
                    .onDeleteCommand { model.requestTrashSelection() }
                    .onMoveCommand { dir in
                        moveSelection(dir, in: items)
                        if let id = model.selection.first { withAnimation { proxy.scrollTo(id, anchor: nil) } }
                    }
                    .onExitCommand { model.clearSelection() }
                    .id(current.id)
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
                }
            }
        }
    }

    private func contextNodes(for node: FileNode, in items: [FileNode]) -> [FileNode] {
        let selected = model.selectedNodes(in: items)
        if selected.contains(where: { $0.id == node.id }) && selected.count > 1 { return selected }
        return [node]
    }

    private func open(_ node: FileNode) {
        if node.isDirectory && !node.isPackage {
            withAnimation(.snappyUI) { engine.enter(node) }
            model.clearSelection()
        } else {
            model.quickLook([node.url])
        }
    }

    private func moveSelection(_ dir: MoveCommandDirection, in items: [FileNode]) {
        guard !items.isEmpty else { return }
        let currentIndex = items.firstIndex { model.selection.contains($0.id) }
        var next = 0
        switch dir {
        case .down: next = min(items.count - 1, (currentIndex ?? -1) + 1)
        case .up: next = max(0, (currentIndex ?? items.count) - 1)
        case .left: model.engine.goUp(); return
        case .right:
            if let i = currentIndex, items[i].isDirectory { open(items[i]) }
            return
        @unknown default: return
        }
        model.select(items[next])
    }
}

struct FileRow: View {
    let node: FileNode
    let parentSize: Int64
    let isSelected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    private var fraction: Double {
        guard parentSize > 0 else { return 0 }
        return Double(node.size) / Double(parentSize)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: node.icon)
                .resizable()
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.08), radius: 1, y: 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(node.name)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(node.isHidden ? 0.6 : 1)
                HStack(spacing: 5) {
                    Text(node.isDirectory && !node.isPackage ? "\(node.itemCount.formatted()) items" : node.kindDescription)
                    if let d = node.modificationDate {
                        Text("·")
                        Text(DateFormat.relativeString(d))
                    }
                    if node.unreadable {
                        Text("·")
                        Label("No access", systemImage: "lock.fill").foregroundStyle(SafetyLevel.caution.color)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SafetyBadge(level: node.assessment.level)
                .frame(width: 84, alignment: .leading)

            SizeBar(fraction: fraction, color: barColor)
                .frame(width: 120)

            Text(node.size.bytesString)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SizeTier(node.size).color)
                .frame(width: 84, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)
                .opacity(node.isDirectory && !node.isPackage ? 1 : 0)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.05) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onSelect() }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.15), value: isSelected)
    }

    private var barColor: Color {
        SizeTier(node.size).color
    }
}

/// Shared right-click menu for file nodes.
struct NodeContextMenu: View {
    @EnvironmentObject var model: AppModel
    let nodes: [FileNode]
    var open: (() -> Void)? = nil

    var body: some View {
        if nodes.count == 1, let n = nodes.first {
            if n.isDirectory && !n.isPackage, let open {
                Button("Open") { open() }
            }
            Button("Quick Look") { model.quickLook([n.url]) }
            Button("Reveal in Finder") { model.reveal([n.url]) }
            if n.isDirectory && !n.isPackage {
                Button("Show Media Inside") { model.showMedia(in: n.url) }
            } else if MediaKind(category: n.category) != nil {
                Button("Show Media in This Folder") { model.showMedia(in: n.url, isDirectory: false) }
            }
            Button("Copy Path") { model.copyPath(n.url) }
            Divider()
            Button("Add to Exclusions") {
                var ex = model.settings.excludedPaths
                if !ex.contains(n.url.path) { ex.append(n.url.path) }
                model.settings.excludedPaths = ex
                model.show(Toast(title: "Excluded from future scans", detail: n.url.path, style: .info))
            }
            Divider()
            Button(n.assessment.canDelete ? "Move to Trash…" : "Protected — can't be trashed", role: .destructive) {
                model.requestTrash(nodes: [n])
            }
            .disabled(!n.assessment.canDelete)
        } else {
            Button("Quick Look \(nodes.count) Items") { model.quickLook(nodes.map(\.url)) }
            Button("Reveal in Finder") { model.reveal(nodes.map(\.url)) }
            Divider()
            Button("Move \(nodes.count) Items to Trash…", role: .destructive) {
                model.requestTrash(nodes: nodes)
            }
        }
    }
}
