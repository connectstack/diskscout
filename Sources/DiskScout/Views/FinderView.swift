import SwiftUI
import AppKit

/// "Large & Old": find big and forgotten files anywhere under the current folder.
struct FinderView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine

    enum Filter: String, CaseIterable, Identifiable {
        case large = "Largest files"
        case old = "Old & unused"
        var id: String { rawValue }
    }

    @State private var filter: Filter = .large
    @State private var thresholdMonths: Double = 12
    @State private var minSizeMB: Double = 50
    @State private var onlyPersonal = false
    @State private var results: [FileNode] = []
    @State private var computing = false

    private var selected: [FileNode] { results.filter { model.selection.contains($0.id) } }
    private var selectedSize: Int64 { selected.reduce(0) { $0 + $1.size } }

    var body: some View {
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
                controls
                Divider()
                list
            }
            if !selected.isEmpty {
                actionBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.2), value: selected.isEmpty)
        .task(id: computeKey) { await recompute() }
    }

    private var computeKey: String {
        "\(engine.current?.id.uuidString ?? "")|\(filter.rawValue)|\(Int(thresholdMonths))|\(Int(minSizeMB))|\(onlyPersonal)|\(engine.current?.size ?? 0)"
    }

    private func recompute() async {
        guard let current = engine.current else { results = []; return }
        computing = true
        let cutoff = Calendar.current.date(byAdding: .month, value: -Int(thresholdMonths), to: .now) ?? .distantPast
        let minBytes = Int64(minSizeMB * 1_000_000)
        let f = filter
        let personal = onlyPersonal
        let out: [FileNode] = await Task.detached(priority: .userInitiated) {
            var files = current.allFiles().filter { $0.size >= minBytes }
            if f == .old {
                files = files.filter { ($0.mostRecentActivity ?? .distantPast) < cutoff }
            }
            if personal {
                files = files.filter { [.documents, .photos, .video, .audio, .archives, .other].contains($0.category) && $0.assessment.level == .review }
            }
            files.sort { $0.size > $1.size }
            return Array(files.prefix(300))
        }.value
        withAnimation(.snappyUI) { results = out }
        computing = false
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)
                Toggle(isOn: $onlyPersonal) { Text("Personal files only").font(.system(size: 11.5)) }
                    .toggleStyle(.checkbox)
                    .help("Hide app data and system items so you only see documents, media and downloads.")
                Spacer()
                if computing { ProgressView().controlSize(.small) }
                Text("\(results.count) file\(results.count == 1 ? "" : "s") · \(results.reduce(0) { $0 + $1.size }.bytesString)")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: 18) {
                sliderRow(title: "Min size", value: $minSizeMB, range: 1...5000, label: minSizeMB >= 1000 ? String(format: "%.1f GB", minSizeMB / 1000) : "\(Int(minSizeMB)) MB")
                if filter == .old {
                    sliderRow(title: "Unused for", value: $thresholdMonths, range: 1...60, label: thresholdLabel)
                        .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                Spacer()
            }
            .animation(.snappyUI, value: filter)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sliderRow(title: String, value: Binding<Double>, range: ClosedRange<Double>, label: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            Slider(value: value, in: range, step: 1).frame(width: 170)
            Text(label).font(.system(size: 11.5, weight: .medium).monospacedDigit()).frame(width: 56, alignment: .leading)
        }
    }

    private var thresholdLabel: String {
        let months = Int(thresholdMonths)
        if months >= 12, months % 12 == 0 { return "\(months / 12) yr" }
        return "\(months) mo"
    }

    // MARK: List

    @ViewBuilder
    private var list: some View {
        if results.isEmpty && !computing {
            EmptyState(systemImage: filter == .large ? "scalemass" : "clock.arrow.circlepath",
                       title: "Nothing matches",
                       message: filter == .large ? "No files this large in “\(engine.current?.name ?? "")”. Lower the minimum size." : "No files this old and large. Try a shorter time or a smaller minimum size.",
                       tint: .secondary)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(results) { file in
                        FinderRow(file: file, isSelected: model.selection.contains(file.id), showAge: filter == .old,
                                  onSelect: { model.select(file, extend: Modifiers.commandDown, range: results, shift: Modifiers.shiftDown) },
                                  onOpen: { model.quickLook([file.url]) })
                        .contextMenu { NodeContextMenu(nodes: selected.contains(where: { $0.id == file.id }) && selected.count > 1 ? selected : [file]) }
                    }
                }
                .padding(8)
                .padding(.bottom, selected.isEmpty ? 0 : 70)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.space) { model.quickLookSelection(); return .handled }
            .onDeleteCommand { model.requestTrash(nodes: selected) }
            .onExitCommand { model.clearSelection() }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            Text("\(selected.count) selected").font(.system(size: 12.5, weight: .semibold))
            Spacer()
            BytesText(bytes: selectedSize, font: .system(size: 20, weight: .bold, design: .rounded)).foregroundStyle(SizeTier(selectedSize).color)
            Button("Clear") { model.clearSelection() }.buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Button { model.requestTrash(nodes: selected) } label: { Label("Review & Trash…", systemImage: "trash") }
                .buttonStyle(PillButtonStyle(color: SafetyLevel.protected.color))
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) { Divider() }
    }
}

private struct FinderRow: View {
    let file: FileNode
    let isSelected: Bool
    let showAge: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ThumbnailView(url: file.url, size: 34).frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 5) {
                    Text(file.url.deletingLastPathComponent().path.replacingOccurrences(of: SafetyClassifier.home, with: "~"))
                        .lineLimit(1).truncationMode(.middle)
                    if showAge, let d = file.mostRecentActivity {
                        Text("· last used \(DateFormat.relativeString(d))")
                    } else if let d = file.modificationDate {
                        Text("· \(DateFormat.relativeString(d))")
                    }
                }
                .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            SafetyBadge(level: file.assessment.level).frame(width: 84, alignment: .leading)
            Text(file.size.bytesString)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(SizeTier(file.size).color)
                .frame(width: 84, alignment: .trailing)
        }
        .padding(.vertical, 6).padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Color.accentColor.opacity(0.18) : (hovering ? Color.primary.opacity(0.05) : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture(count: 1) { onSelect() }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
