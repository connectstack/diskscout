import SwiftUI
import AppKit

struct InspectorPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine

    var body: some View {
        Group {
            if model.mode == .smartClean {
                if let item = model.cleanupInspected {
                    CleanupItemInspector(item: item)
                        .id(item.id)
                } else {
                    SmartCleanInspector()
                }
            } else {
                let nodes = model.nodes(for: model.selection)
                if nodes.count == 1, let n = nodes.first {
                    NodeInspector(node: n).id(n.id)
                } else if nodes.count > 1 {
                    MultiInspector(nodes: nodes)
                } else if let cur = engine.current {
                    FolderInspector(node: cur).id(cur.id)
                } else {
                    EmptyState(systemImage: "sidebar.right", title: "Inspector", message: "Select an item to see a preview, details and whether it's safe to delete.", tint: .secondary)
                }
            }
        }
        .animation(.snappyUI, value: model.selection)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

// MARK: - Single node

struct NodeInspector: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                previewCard
                VStack(alignment: .leading, spacing: 4) {
                    Text(node.name)
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(3)
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(node.kindDescription)
                        Text("·")
                        Text(node.size.bytesString).fontWeight(.semibold).foregroundStyle(SizeTier(node.size).color)
                        if node.isDirectory && !node.isPackage {
                            Text("·")
                            Text("\(node.itemCount.formatted()) items")
                        }
                    }
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
                SafetyCard(assessment: node.assessment)
                DetailsGrid(rows: details)
                actions
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.opacity)
    }

    private var previewCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [node.assessment.level.color.opacity(0.22), node.assessment.level.color.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing))
            ThumbnailView(url: node.url, size: 150)
                .padding(16)
        }
        .frame(height: 190)
        .onTapGesture(count: 2) { model.quickLook([node.url]) }
        .help("Double-click for Quick Look")
    }

    /// Folders get "Show Media" (everything inside, however nested); media files get it for their folder.
    private var showMediaAction: InspectorActions.Action? {
        if node.isDirectory && !node.isPackage {
            return .init(title: "Show Media", systemImage: "photo.on.rectangle.angled", tint: FileCategory.photos.color) { model.showMedia(in: node.url) }
        }
        if MediaKind(category: node.category) != nil {
            return .init(title: "Show Media", systemImage: "photo.on.rectangle.angled", tint: FileCategory.photos.color) { model.showMedia(in: node.url, isDirectory: false) }
        }
        return nil
    }

    private var details: [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("Where", node.url.deletingLastPathComponent().path))
        rows.append(("Category", node.category.rawValue))
        if let c = node.creationDate { rows.append(("Created", DateFormat.string(c))) }
        if let m = node.modificationDate { rows.append(("Modified", DateFormat.string(m))) }
        if let a = node.accessDate { rows.append(("Last opened", DateFormat.string(a))) }
        if node.isHidden { rows.append(("Hidden", "Yes")) }
        return rows
    }

    private var actions: some View {
        VStack(spacing: 8) {
            InspectorActions(actions: [
                .init(title: "Quick Look", systemImage: "eye") { model.quickLook([node.url]) },
                .init(title: "Show in Finder", systemImage: "folder") { model.reveal([node.url]) },
                showMediaAction
            ].compactMap { $0 })

            Button(role: .destructive) { model.requestTrash(nodes: [node]) } label: {
                Label(node.assessment.canDelete ? "Move to Trash…" : "Protected by DiskScout", systemImage: node.assessment.canDelete ? "trash" : "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(node.assessment.canDelete ? SafetyLevel.protected.color : .gray)
            .disabled(!node.assessment.canDelete)
            .controlSize(.large)
        }
    }
}

// MARK: - Multi

struct MultiInspector: View {
    @EnvironmentObject var model: AppModel
    let nodes: [FileNode]

    private var total: Int64 { nodes.reduce(0) { $0 + $1.size } }
    private var byLevel: [(SafetyLevel, Int)] {
        SafetyLevel.allCases.compactMap { l in
            let c = nodes.filter { $0.assessment.level == l }.count
            return c > 0 ? (l, c) : nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill)
                    HStack(spacing: -18) {
                        ForEach(nodes.prefix(4)) { n in
                            Image(nsImage: n.icon).resizable().frame(width: 56, height: 56)
                                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                        }
                    }
                }
                .frame(height: 120)
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(nodes.count) items selected").font(.system(size: 16, weight: .semibold))
                    BytesText(bytes: total, font: .system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(SizeTier(total).color)
                }
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(byLevel, id: \.0) { level, count in
                        HStack {
                            SafetyBadge(level: level)
                            Text("\(count) item\(count == 1 ? "" : "s")").font(.callout)
                            Spacer()
                            Text(nodes.filter { $0.assessment.level == level }.reduce(0) { $0 + $1.size }.bytesString)
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .card()
                let blocked = nodes.filter { !$0.assessment.canDelete }.count
                if blocked > 0 {
                    Label("\(blocked) protected item\(blocked == 1 ? "" : "s") will be skipped.", systemImage: "lock.shield.fill")
                        .font(.callout).foregroundStyle(SafetyLevel.protected.color)
                }
                HStack(spacing: 8) {
                    Button { model.quickLook(nodes.map(\.url)) } label: { Label("Quick Look", systemImage: "eye") }
                    Button { model.reveal(nodes.map(\.url)) } label: { Label("Show in Finder", systemImage: "folder") }
                }
                .buttonStyle(.bordered)
                Button(role: .destructive) { model.requestTrash(nodes: nodes) } label: {
                    Label("Move \(nodes.count - blocked) to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SafetyLevel.protected.color)
                .controlSize(.large)
                .disabled(nodes.count - blocked == 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Folder summary

struct FolderInspector: View {
    @EnvironmentObject var model: AppModel
    let node: FileNode

    var body: some View {
        let totals = node.safetyTotals()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(nsImage: node.icon).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(node.name).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                        Text("\(node.itemCount.formatted()) items · \(node.size.bytesString)").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("What's in here, by safety").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    SegmentBar(segments: SafetyLevel.allCases.compactMap { l in
                        guard let v = totals[l], v > 0 else { return nil }
                        return SegmentBar.Segment(id: l.shortTitle, value: Double(v), color: l.color, label: l.shortTitle)
                    }, height: 10)
                    ForEach(SafetyLevel.allCases, id: \.self) { l in
                        if let v = totals[l], v > 0 {
                            HStack {
                                SafetyBadge(level: l)
                                Text(l.tagline).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                Spacer()
                                Text(v.bytesString).font(.system(size: 11.5, weight: .semibold).monospacedDigit())
                            }
                        }
                    }
                }
                .card()
                SafetyCard(assessment: node.assessment)
                InspectorActions(actions: [
                    .init(title: "Show in Finder", systemImage: "folder") { model.reveal([node.url]) },
                    .init(title: "Show Media", systemImage: "photo.on.rectangle.angled", tint: FileCategory.photos.color) { model.showMedia(in: node.url) }
                ])
                Text("Select any item on the left to preview it and see why it's rated the way it is. Show Media gathers every photo, video and audio file inside this folder, however deeply nested.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Cleanup item

struct CleanupItemInspector: View {
    @EnvironmentObject var model: AppModel
    let item: CleanupItem

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [item.category.color.opacity(0.25), item.category.color.opacity(0.05)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    ThumbnailView(url: item.url, size: 130).padding(16)
                }
                .frame(height: 170)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.system(size: 16, weight: .semibold)).lineLimit(3)
                    HStack(spacing: 6) {
                        IconTile(systemImage: item.category.systemImage, color: item.category.color, size: 16)
                        Text(item.category.rawValue)
                        Text("·")
                        Text(item.size.bytesString).fontWeight(.semibold).foregroundStyle(SizeTier(item.size).color)
                    }
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                SafetyCard(assessment: item.assessment)
                DetailsGrid(rows: [("Where", item.url.path)] + (item.modified.map { [("Modified", DateFormat.string($0))] } ?? []))
                InspectorActions(actions: [
                    .init(title: "Quick Look", systemImage: "eye") { model.quickLook([item.url]) },
                    .init(title: "Show in Finder", systemImage: "folder") { model.reveal([item.url]) },
                    item.isDirectory ? .init(title: "Show Media", systemImage: "photo.on.rectangle.angled", tint: FileCategory.photos.color) { model.showMedia(in: item.url) } : nil
                ].compactMap { $0 })
                Button(role: .destructive) { model.requestCleanup(items: [item]) } label: {
                    Label(item.action == .emptyTrash ? "Empty Trash…" : "Move to Trash…", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(SafetyLevel.protected.color)
                .controlSize(.large)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SmartCleanInspector: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("How DiskScout rates things")
                    .font(.system(size: 14, weight: .semibold))
                ForEach(SafetyLevel.allCases, id: \.self) { level in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: level.systemImage)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(level.color)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title).font(.system(size: 12.5, weight: .semibold))
                            Text(level.tagline).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(level.color.opacity(0.08)))
                }
                Text("Click any row in Smart Clean to see exactly what it is and what happens if you remove it. Everything goes to the Trash first, so you can always put it back.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Shared pieces

/// Row of bordered action buttons. Three labelled buttons rarely fit the inspector width,
/// so the fallback keeps the first two on one row and gives the third its own full-width row.
struct InspectorActions: View {
    struct Action: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        var tint: Color? = nil
        let run: () -> Void

        init(title: String, systemImage: String, tint: Color? = nil, run: @escaping () -> Void) {
            self.title = title; self.systemImage = systemImage; self.tint = tint; self.run = run
        }
    }

    let actions: [Action]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { ForEach(actions) { button($0) } }
            VStack(spacing: 8) {
                HStack(spacing: 8) { ForEach(actions.prefix(2)) { button($0) } }
                ForEach(actions.dropFirst(2)) { button($0, fullWidth: true) }
            }
            VStack(spacing: 8) { ForEach(actions) { button($0, fullWidth: true) } }
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(maxWidth: .infinity)
    }

    private func button(_ a: Action, fullWidth: Bool = false) -> some View {
        Button(action: a.run) {
            Label(a.title, systemImage: a.systemImage)
                .lineLimit(1)
                .fixedSize()
                .frame(maxWidth: fullWidth ? .infinity : nil)
        }
        .tint(a.tint ?? .accentColor)
        .help(a.title)
    }
}

struct SafetyCard: View {
    let assessment: SafetyAssessment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: assessment.level.systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(assessment.level.title)
                    .font(.system(size: 12.5, weight: .bold))
                Spacer()
                if assessment.regenerates {
                    Label("Rebuilds itself", systemImage: "arrow.triangle.2.circlepath")
                        .font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(Color.white.opacity(0.35)))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(LinearGradient(colors: [assessment.level.color, assessment.level.color.opacity(0.8)], startPoint: .leading, endPoint: .trailing))

            VStack(alignment: .leading, spacing: 6) {
                Text(assessment.headline).font(.system(size: 13, weight: .semibold))
                Text(assessment.explanation).font(.system(size: 12)).foregroundStyle(.primary.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                if let hint = assessment.recreateHint {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal").font(.system(size: 10))
                        Text(hint).font(.system(size: 11, design: .monospaced))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                }
            }
            .padding(12)
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(assessment.level.color.opacity(0.08)))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(assessment.level.color.opacity(0.3)))
    }
}

struct DetailsGrid: View {
    let rows: [(String, String)]
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    Text(row.0)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .trailing)
                    Text(row.1)
                        .font(.system(size: 11.5))
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .card(padding: 12)
    }
}
