import SwiftUI
import AppKit

struct SmartCleanView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cleaner: CleanupScanner
    @State private var collapsed: Set<CleanupCategory> = []

    private var selectedItems: [CleanupItem] {
        cleaner.items.filter { model.selectedCleanupIDs.contains($0.id) }
    }
    private var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    summary
                    if cleaner.items.isEmpty && !cleaner.isScanning && cleaner.hasScanned && !cleaner.wasStopped {
                        EmptyState(systemImage: "sparkles", title: "Your Mac is tidy",
                                   message: "DiskScout couldn't find any junk in the usual places. Try Browse or Large & Old to hunt down big personal files.",
                                   tint: SafetyLevel.safe.color,
                                   action: ("Scan again", { cleaner.scan() }))
                            .frame(minHeight: 300)
                    }
                    ForEach(CleanupCategory.allCases) { category in
                        let items = cleaner.items(in: category)
                        if !items.isEmpty {
                            CategorySection(
                                category: category,
                                items: items,
                                isCollapsed: collapsed.contains(category),
                                toggleCollapse: { withAnimation(.snappyUI) { if collapsed.contains(category) { collapsed.remove(category) } else { collapsed.insert(category) } } }
                            )
                            .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        } else if cleaner.isScanning && cleaner.currentCategory == category {
                            scanningSection(category)
                                .transition(.opacity)
                        }
                    }
                }
                .padding(16)
                .padding(.bottom, model.selectedCleanupIDs.isEmpty ? 0 : 70)
                .animation(.spring(duration: 0.5, bounce: 0.1), value: cleaner.items.count)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { model.cleanupInspected = nil })

            if !model.selectedCleanupIDs.isEmpty {
                actionBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.selectedCleanupIDs.isEmpty)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) { model.quickLookSelection(); return .handled }
        .onDeleteCommand { model.requestCleanup(ids: model.selectedCleanupIDs) }
    }

    // MARK: - Summary

    private var summary: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").foregroundStyle(QuickLocations.smartClean.color)
                    Text("Smart Clean").font(.system(size: 17, weight: .bold))
                    if let last = cleaner.lastScan, !cleaner.isScanning {
                        Text("· checked \(DateFormat.relativeString(last))").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                Text(headline)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(SafetyLevel.allCases.filter { $0 != .protected }, id: \.self) { level in
                        let total = cleaner.total(level: level)
                        if total > 0 || level == .safe {
                            HStack(spacing: 5) {
                                Image(systemName: level.systemImage).font(.system(size: 10, weight: .bold))
                                Text(level.shortTitle).font(.system(size: 11, weight: .semibold))
                                BytesText(bytes: total, font: .system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(level.color)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(level.color.opacity(0.12)))
                        }
                    }
                }
                .padding(.top, 2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) {
                Button {
                    withAnimation(.snappyUI) {
                        let safeIDs = cleaner.items.filter { $0.assessment.level == .safe }.map(\.id)
                        if safeIDs.allSatisfy({ model.selectedCleanupIDs.contains($0) }) && !safeIDs.isEmpty {
                            model.selectedCleanupIDs.subtract(safeIDs)
                        } else {
                            model.selectedCleanupIDs.formUnion(safeIDs)
                        }
                    }
                } label: {
                    Label(allSafeSelected ? "Deselect safe items" : "Select everything safe", systemImage: "checkmark.shield.fill")
                }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.safe.color, prominent: !allSafeSelected))
                .disabled(cleaner.totalSafe == 0)
                Text("Safe items rebuild themselves. Nothing of yours is in them.")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary)
            }
        }
        .card(padding: 16)
    }

    private var allSafeSelected: Bool {
        let safeIDs = cleaner.items.filter { $0.assessment.level == .safe }.map(\.id)
        return !safeIDs.isEmpty && safeIDs.allSatisfy { model.selectedCleanupIDs.contains($0) }
    }

    private var headline: String {
        if cleaner.isScanning && cleaner.items.isEmpty { return "Checking caches, logs, developer folders, leftovers and more…" }
        if cleaner.wasStopped { return "The scan was stopped, so this list is incomplete. Rescan to check everything." }
        if cleaner.items.isEmpty { return "Nothing to clean right now." }
        let safe = cleaner.totalSafe
        if safe > 0 {
            let rest = cleaner.totalAll - safe
            if rest > 0 {
                return "\(safe.bytesString) can be removed right now with no downside. Another \(rest.bytesString) is worth a look — tap any row to see what it is."
            }
            return "\(safe.bytesString) can be removed right now with no downside. Tap any row to see exactly what it is."
        }
        return "\(cleaner.totalAll.bytesString) found. None of it is automatically safe — review each item before deciding."
    }

    private func scanningSection(_ category: CleanupCategory) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconTile(systemImage: category.systemImage, color: category.color, size: 26)
                Text(category.rawValue).font(.system(size: 13.5, weight: .semibold))
                ProgressView().controlSize(.small)
                Spacer()
            }
            SkeletonRow()
            SkeletonRow()
        }
        .card(padding: 12)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("\(selectedItems.count) item\(selectedItems.count == 1 ? "" : "s") selected")
                    .font(.system(size: 12.5, weight: .semibold))
                HStack(spacing: 6) {
                    ForEach(SafetyLevel.allCases, id: \.self) { l in
                        let c = selectedItems.filter { $0.assessment.level == l }.count
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
            BytesText(bytes: selectedSize, font: .system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(SafetyLevel.safe.color)
            Button("Clear") { withAnimation(.snappyUI) { model.selectedCleanupIDs.removeAll() } }
                .buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Button {
                model.requestCleanup(items: selectedItems)
            } label: {
                Label("Review & Clean…", systemImage: "trash")
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

// MARK: - Category section

private struct CategorySection: View {
    @EnvironmentObject var model: AppModel
    let category: CleanupCategory
    let items: [CleanupItem]
    let isCollapsed: Bool
    let toggleCollapse: () -> Void

    private var total: Int64 { items.reduce(0) { $0 + $1.size } }
    private var allSelected: Bool { items.allSatisfy { model.selectedCleanupIDs.contains($0.id) } }
    private var anySelected: Bool { items.contains { model.selectedCleanupIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !isCollapsed {
                Divider().padding(.top, 10)
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        CleanupRow(item: item,
                                   isChecked: model.selectedCleanupIDs.contains(item.id),
                                   isInspected: model.cleanupInspected?.id == item.id,
                                   toggle: { toggle(item) },
                                   inspect: { model.cleanupInspected = item })
                        .contextMenu {
                            Button("Quick Look") { model.quickLook([item.url]) }
                            Button("Reveal in Finder") { model.reveal([item.url]) }
                            Button("Copy Path") { model.copyPath(item.url) }
                            Divider()
                            Button(item.action == .emptyTrash ? "Empty Trash…" : "Move to Trash…", role: .destructive) { model.requestCleanup(items: [item]) }
                        }
                        .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .leading).combined(with: .opacity)))
                    }
                }
                .padding(.top, 4)
                .animation(.spring(duration: 0.35), value: items.map(\.id))
            }
        }
        .card(padding: 12)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button(action: selectAll) {
                CheckCircle(isOn: allSelected, color: anySelected && !allSelected ? Color.accentColor.opacity(0.5) : .accentColor)
            }
            .buttonStyle(.plain)
            .help(allSelected ? "Deselect all in \(category.rawValue)" : "Select all in \(category.rawValue)")
            IconTile(systemImage: category.systemImage, color: category.color, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(category.rawValue).font(.system(size: 13.5, weight: .semibold))
                    Text("\(items.count)")
                        .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Theme.subtleFill))
                }
                Text(category.blurb).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            BytesText(bytes: total, font: .system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(SizeTier(total).color)
            Button(action: toggleCollapse) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? -90 : 0))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleCollapse() }
    }

    private func selectAll() {
        withAnimation(.snappyUI) {
            let ids = items.map(\.id)
            if allSelected { model.selectedCleanupIDs.subtract(ids) } else { model.selectedCleanupIDs.formUnion(ids) }
        }
    }

    private func toggle(_ item: CleanupItem) {
        withAnimation(.snappyUI) {
            if model.selectedCleanupIDs.contains(item.id) { model.selectedCleanupIDs.remove(item.id) } else { model.selectedCleanupIDs.insert(item.id) }
        }
    }
}

private struct CleanupRow: View {
    let item: CleanupItem
    let isChecked: Bool
    let isInspected: Bool
    let toggle: () -> Void
    let inspect: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) { CheckCircle(isOn: isChecked) }
                .buttonStyle(.plain)
            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                Text(item.subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.assessment.regenerates {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .help("Rebuilt automatically")
            }
            SafetyBadge(level: item.assessment.level)
                .frame(width: 84, alignment: .leading)
            Text(item.size.bytesString)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(SizeTier(item.size).color)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isInspected ? Color.accentColor.opacity(0.14) : (hovering ? Color.primary.opacity(0.045) : .clear))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { inspect() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
