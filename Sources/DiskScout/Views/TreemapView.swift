import SwiftUI
import AppKit

struct TreemapView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine
    @ObservedObject var settings: AppSettings

    @State private var hovered: UUID?

    var body: some View {
        VStack(spacing: 0) {
            BreadcrumbBar(engine: engine, onReveal: { model.reveal([$0]) })
            Divider()
            GeometryReader { geo in
                let items = (engine.current?.sortedChildren ?? []).filter { $0.size > 0 }
                let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
                let bounds = CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6)
                let tiles = (bounds.width > 20 && bounds.height > 20)
                    ? Treemap.layout(values: items.map { (id: $0.id, value: Double($0.size)) }, in: bounds)
                    : []
                ZStack(alignment: .topLeading) {
                    Color.clear.contentShape(Rectangle()).onTapGesture { model.clearSelection() }
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        if let node = lookup[tile.id], tile.rect.width > 4, tile.rect.height > 4 {
                            TreemapTileView(
                                node: node,
                                rect: tile.rect.insetBy(dx: 1.5, dy: 1.5),
                                color: color(for: node, index: index),
                                isHovered: hovered == tile.id,
                                isSelected: model.selection.contains(node.id),
                                onEnter: { hovered = tile.id },
                                onExit: { if hovered == tile.id { hovered = nil } },
                                onSelect: { model.select(node, extend: Modifiers.commandDown) },
                                onOpen: { open(node) },
                                childColor: { child, i in color(for: child, index: i) }
                            )
                            .contextMenu { NodeContextMenu(nodes: [node], open: { open(node) }) }
                        }
                    }
                    if tiles.isEmpty {
                        EmptyState(systemImage: "rectangle.split.3x3", title: "Nothing to visualise", message: "This folder has no sized items.", tint: .secondary)
                    }
                }
                .id(engine.current?.id)
                .transition(.asymmetric(insertion: .scale(scale: 1.06).combined(with: .opacity), removal: .scale(scale: 0.94).combined(with: .opacity)))
                .animation(.spring(duration: 0.45, bounce: 0.1), value: engine.current?.id)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) { model.quickLookSelection(); return .handled }
            .onDeleteCommand { model.requestTrashSelection() }
            .onExitCommand { model.clearSelection() }
            Divider()
            legend
        }
    }

    private func open(_ node: FileNode) {
        if node.isDirectory && !node.isPackage {
            withAnimation(.spring(duration: 0.45, bounce: 0.1)) { engine.enter(node) }
            model.clearSelection()
        } else {
            model.quickLook([node.url])
        }
    }

    private func color(for node: FileNode, index: Int) -> Color {
        switch settings.treemapColors {
        case .safety: return node.assessment.level.color
        case .category: return node.category.color
        case .size: return SizeTier(node.size).color
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            switch settings.treemapColors {
            case .safety:
                ForEach(SafetyLevel.allCases, id: \.self) { l in legendItem(l.color, l.shortTitle) }
            case .category:
                ForEach(FileCategory.allCases.prefix(8)) { c in legendItem(c.color, c.rawValue) }
            case .size:
                legendItem(SizeTier.huge.color, "> 5 GB"); legendItem(SizeTier.large.color, "> 1 GB")
                legendItem(SizeTier.medium.color, "> 100 MB"); legendItem(SizeTier.small.color, "> 10 MB")
            }
            Spacer()
            Text("Double-click to open · Space for Quick Look")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
    }
}

private struct TreemapTileView: View {
    let node: FileNode
    let rect: CGRect
    let color: Color
    let isHovered: Bool
    let isSelected: Bool
    let onEnter: () -> Void
    let onExit: () -> Void
    let onSelect: () -> Void
    let onOpen: () -> Void
    let childColor: (FileNode, Int) -> Color

    private var showLabel: Bool { rect.width > 56 && rect.height > 26 }
    private var showChildren: Bool { node.isDirectory && !node.isPackage && rect.width > 110 && rect.height > 70 && !node.children.isEmpty }
    private let headerHeight: CGFloat = 20

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    LinearGradient(colors: [color.opacity(isHovered ? 0.95 : 0.78), color.opacity(isHovered ? 0.8 : 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isSelected ? Color.white : Color.white.opacity(isHovered ? 0.7 : 0.25), lineWidth: isSelected ? 2 : 1)
                )
                .shadow(color: .black.opacity(isHovered ? 0.25 : 0.08), radius: isHovered ? 8 : 2, y: isHovered ? 4 : 1)

            if showChildren {
                nestedChildren
                    .padding(.top, headerHeight)
                    .padding(4)
            }

            if showLabel {
                HStack(spacing: 4) {
                    if node.assessment.level != .review {
                        Image(systemName: node.assessment.level.systemImage)
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(node.name)
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if rect.width > 120 {
                        Text(node.size.bytesString)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.5), radius: 1.5)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: rect.width, alignment: .leading)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .scaleEffect(isHovered ? 1.015 : 1)
        .zIndex(isHovered ? 1 : 0)
        .offset(x: rect.minX, y: rect.minY)
        .onHover { hovering in if hovering { onEnter() } else { onExit() } }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onSelect() }
        .help("\(node.name) — \(node.size.bytesString) · \(node.assessment.level.title): \(node.assessment.headline)")
        .animation(.spring(duration: 0.25), value: isHovered)
        .animation(.spring(duration: 0.35), value: rect)
    }

    private var nestedChildren: some View {
        GeometryReader { geo in
            let kids = node.sortedChildren.filter { $0.size > 0 }.prefix(40)
            let lookup = Dictionary(uniqueKeysWithValues: kids.map { ($0.id, $0) })
            let tiles = (geo.size.width > 8 && geo.size.height > 8)
                ? Treemap.layout(values: kids.map { (id: $0.id, value: Double($0.size)) }, in: CGRect(origin: .zero, size: geo.size))
                : []
            ZStack(alignment: .topLeading) {
                ForEach(Array(tiles.enumerated()), id: \.element.id) { i, t in
                    if let kid = lookup[t.id] {
                        let r = t.rect.insetBy(dx: 1, dy: 1)
                        if r.width > 2 && r.height > 2 {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(childColor(kid, i).opacity(0.55))
                                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                                .overlay(alignment: .topLeading) {
                                    if r.width > 46 && r.height > 16 {
                                        Text(kid.name)
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.9))
                                            .lineLimit(1)
                                            .padding(.horizontal, 4).padding(.vertical, 2)
                                            .frame(width: r.width, alignment: .leading)
                                    }
                                }
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                                .help("\(kid.name) — \(kid.size.bytesString)")
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}
