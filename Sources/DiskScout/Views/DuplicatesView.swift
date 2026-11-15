import SwiftUI
import AppKit

struct DuplicatesView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine
    @StateObject private var finder = DuplicateFinder()
    @State private var expanded: Set<UUID> = []
    @State private var marked: Set<UUID> = []   // files chosen for deletion

    private var markedNodes: [FileNode] {
        finder.groups.flatMap(\.files).filter { marked.contains($0.id) }
    }
    private var markedSize: Int64 { markedNodes.reduce(0) { $0 + $1.size } }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            if !marked.isEmpty {
                actionBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: marked.isEmpty)
        .onChange(of: engine.current?.id) { _, _ in
            finder.cancel()
            finder.groups = []
            finder.lastScannedRootID = nil
            marked = []
        }
        // After a trash (or an undo), what's on screen must match what's on disk.
        .onChange(of: model.trashPlan == nil) { _, closed in
            guard closed else { return }
            finder.pruneMissing()
            marked.formIntersection(Set(finder.groups.flatMap(\.files).map(\.id)))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(systemImage: "doc.on.doc.fill", color: Color(red: 0.74, green: 0.47, blue: 1.0), size: 30)
            VStack(alignment: .leading, spacing: 2) {
                if finder.isWorking {
                    Text("Comparing file contents…").font(.system(size: 13.5, weight: .semibold))
                    Text("\(finder.checked) of \(finder.totalToCheck) candidates hashed").font(.system(size: 11)).foregroundStyle(.secondary)
                } else if !finder.groups.isEmpty {
                    Text("\(finder.groups.count) duplicate group\(finder.groups.count == 1 ? "" : "s")").font(.system(size: 13.5, weight: .semibold))
                    HStack(spacing: 4) {
                        Text("Wasted:").foregroundStyle(.secondary)
                        Text(finder.totalWasted.bytesString).fontWeight(.semibold).foregroundStyle(SafetyLevel.caution.color)
                        if finder.skipped > 0 { Text("· \(finder.skipped) unreadable").foregroundStyle(.secondary) }
                    }.font(.system(size: 11))
                } else if finder.lastScannedRootID != nil {
                    Text("No duplicates").font(.system(size: 13.5, weight: .semibold))
                    Text("Every file in “\(engine.current?.name ?? "")” is unique.").font(.system(size: 11)).foregroundStyle(.secondary)
                } else {
                    Text("Find duplicates in “\(engine.current?.name ?? "this folder")”").font(.system(size: 13.5, weight: .semibold))
                    Text("Groups files by size, then confirms byte-for-byte with SHA-256. Files under \(model.settings.duplicateMinSizeKB) KB are ignored.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if finder.isWorking {
                ProgressView(value: Double(finder.checked), total: Double(max(finder.totalToCheck, 1)))
                    .frame(width: 160)
                Button("Stop") { finder.cancel() }.buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            } else if !finder.groups.isEmpty {
                Menu {
                    Button("Keep newest copy in each group") { autoMark(keep: .newest) }
                    Button("Keep oldest copy in each group") { autoMark(keep: .oldest) }
                    Button("Keep copy with shortest path") { autoMark(keep: .shortestPath) }
                    Divider()
                    Button("Clear marks") { withAnimation { marked = [] } }
                } label: {
                    Label("Auto-select", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Re-scan") { run() }.buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            } else {
                Button { run() } label: { Label("Find Duplicates", systemImage: "magnifyingglass") }
                    .buttonStyle(PillButtonStyle())
                    .disabled(engine.current == nil)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if finder.groups.isEmpty && !finder.isWorking {
            if finder.lastScannedRootID != nil {
                EmptyState(systemImage: "checkmark.seal.fill", title: "No duplicates here", message: "Nothing in this folder is stored twice.", tint: SafetyLevel.safe.color)
            } else {
                EmptyState(systemImage: "doc.on.doc", title: "Duplicate finder",
                           message: "Photos exported twice, re-downloaded installers, copied project folders… Find identical files and keep just one.",
                           tint: Color(red: 0.74, green: 0.47, blue: 1.0),
                           action: ("Find Duplicates", { run() }))
            }
        } else if finder.isWorking && finder.groups.isEmpty {
            VStack(spacing: 10) {
                Radar().frame(width: 110, height: 110)
                Text("Hashing \(finder.checked) / \(finder.totalToCheck)…").font(.callout).foregroundStyle(.secondary).monospacedDigit()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(finder.groups) { group in
                        DuplicateGroupCard(
                            group: group,
                            isExpanded: expanded.contains(group.id),
                            marked: marked,
                            toggleExpand: { withAnimation(.snappyUI) { if expanded.contains(group.id) { expanded.remove(group.id) } else { expanded.insert(group.id) } } },
                            toggleMark: { id in withAnimation(.snappyUI) { if marked.contains(id) { marked.remove(id) } else { marked.insert(id) } } }
                        )
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(14)
                .padding(.bottom, marked.isEmpty ? 0 : 70)
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(marked.count) cop\(marked.count == 1 ? "y" : "ies") marked for Trash").font(.system(size: 12.5, weight: .semibold))
                Text("The copies you keep are untouched.").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            BytesText(bytes: markedSize, font: .system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(SafetyLevel.caution.color)
            Button("Clear") { withAnimation { marked = [] } }.buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Button { model.requestTrash(nodes: markedNodes) } label: { Label("Review & Trash…", systemImage: "trash") }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.protected.color))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Actions

    private func run() {
        guard let node = engine.current else { return }
        marked = []
        finder.find(in: node, minSize: Int64(model.settings.duplicateMinSizeKB) * 1024)
    }

    private enum KeepRule { case newest, oldest, shortestPath }

    private func autoMark(keep rule: KeepRule) {
        var m = Set<UUID>()
        for g in finder.groups {
            let keep: FileNode?
            switch rule {
            case .newest: keep = g.files.max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            case .oldest: keep = g.files.min { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
            case .shortestPath: keep = g.files.min { $0.url.path.count < $1.url.path.count }
            }
            for f in g.files where f.id != keep?.id && f.assessment.canDelete { m.insert(f.id) }
        }
        withAnimation(.snappyUI) { marked = m }
    }
}

private struct DuplicateGroupCard: View {
    @EnvironmentObject var model: AppModel
    let group: DuplicateGroup
    let isExpanded: Bool
    let marked: Set<UUID>
    let toggleExpand: () -> Void
    let toggleMark: (UUID) -> Void

    private var markedInGroup: Int { group.files.filter { marked.contains($0.id) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                ThumbnailView(url: group.files[0].url, size: 40)
                    .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.files.first?.name ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text("\(group.files.count) identical copies · \(group.size.bytesString) each").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if markedInGroup > 0 {
                    Text("\(markedInGroup) marked")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SafetyLevel.caution.color)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(SafetyLevel.caution.color.opacity(0.14)))
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text("wasted").font(.system(size: 9.5)).foregroundStyle(.secondary)
                    Text(group.wastedSpace.bytesString).font(.system(size: 13.5, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(SafetyLevel.caution.color)
                }
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .frame(width: 20)
            }
            .contentShape(Rectangle())
            .onTapGesture { toggleExpand() }

            if isExpanded {
                Divider().padding(.vertical, 8)
                VStack(spacing: 2) {
                    ForEach(group.files) { file in
                        DuplicateFileRow(file: file, isMarked: marked.contains(file.id), toggle: { toggleMark(file.id) })
                            .contextMenu { NodeContextMenu(nodes: [file]) }
                    }
                }
                .transition(.opacity)
            }
        }
        .card(padding: 12)
    }
}

private struct DuplicateFileRow: View {
    @EnvironmentObject var model: AppModel
    let file: FileNode
    let isMarked: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { CheckCircle(isOn: isMarked, color: SafetyLevel.caution.color) }
                .buttonStyle(.plain)
                .disabled(!file.assessment.canDelete)
                .help(isMarked ? "Marked for Trash" : "Mark this copy for Trash")
            VStack(alignment: .leading, spacing: 1) {
                Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: SafetyClassifier.home, with: "~"))
                    .font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    if let d = file.modificationDate { Text("Modified \(DateFormat.relativeString(d))") }
                    SafetyBadge(level: file.assessment.level, compact: true)
                }
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            Spacer()
            if isMarked {
                Text("Trash").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SafetyLevel.caution.color)
            } else {
                Text("Keep").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SafetyLevel.safe.color)
            }
            HoverButton(systemImage: "eye", help: "Quick Look") { model.quickLook([file.url]) }
            HoverButton(systemImage: "folder", help: "Reveal in Finder") { model.reveal([file.url]) }
        }
        .padding(.vertical, 5).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 7).fill(isMarked ? SafetyLevel.caution.color.opacity(0.08) : (hovering ? Color.primary.opacity(0.04) : .clear)))
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
