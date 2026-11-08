import SwiftUI

struct ModeBar: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine
    @ObservedObject var settings: AppSettings
    @Namespace private var ns

    var body: some View {
        HStack(spacing: 10) {
            ViewThatFits(in: .horizontal) {
                segmented(showLabels: true)
                segmented(showLabels: false)
            }
            Spacer(minLength: 0)
            trailingControls
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func segmented(showLabels: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(ViewMode.allCases) { m in
                modeButton(m, showLabel: showLabels || model.mode == m)
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.subtleFill))
    }

    private func modeButton(_ m: ViewMode, showLabel: Bool) -> some View {
        let selected = model.mode == m
        let disabled = m.needsScan && engine.root == nil && !engine.isScanning
        return Button {
            withAnimation(.snappyUI) { model.mode = m }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: m.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                if showLabel {
                    Text(m.rawValue)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                }
            }
            .fixedSize()
            .padding(.horizontal, showLabel ? 11 : 9)
            .padding(.vertical, 6)
            .foregroundStyle(selected ? Color.white : (disabled ? Color.secondary : Color.primary))
            .background {
                if selected {
                    Capsule()
                        .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: Color.accentColor.opacity(0.35), radius: 5, y: 2)
                        .matchedGeometryEffect(id: "mode-selection", in: ns)
                }
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(disabled ? "Scan a folder first" : m.rawValue + " (⌘\(m.shortcut.character))")
    }

    @ViewBuilder
    private var trailingControls: some View {
        switch model.mode {
        case .browse:
            Picker("Sort", selection: $model.sortOrder) {
                ForEach(SortOrder.allCases) { Text("Sort: \($0.rawValue)").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        case .treemap:
            Picker("Color by", selection: Binding(get: { settings.treemapColors }, set: { settings.treemapColors = $0 })) {
                ForEach(TreemapColorMode.allCases) { Text("Color: \($0.rawValue)").tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        default:
            EmptyView()
        }
    }
}

struct BreadcrumbBar: View {
    @ObservedObject var engine: ScanEngine
    let onReveal: (URL) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(engine.path.enumerated()), id: \.element.id) { index, node in
                        let isLast = index == engine.path.count - 1
                        Button { engine.goTo(node) } label: {
                            HStack(spacing: 4) {
                                if index == 0 {
                                    Image(systemName: node.url.path == "/" ? "internaldrive.fill" : "folder.fill")
                                        .font(.system(size: 10))
                                }
                                Text(node.name).lineLimit(1)
                            }
                            .font(.system(size: 12, weight: isLast ? .semibold : .regular))
                            .foregroundStyle(isLast ? Color.primary : Color.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 6).fill(isLast ? Theme.subtleFill : .clear))
                        }
                        .buttonStyle(.plain)
                        if !isLast {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.horizontal, 10)
            }
            Spacer(minLength: 0)
            if let cur = engine.current {
                Text("\(cur.itemCount.formatted()) items")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 12)
            }
        }
        .frame(height: 30)
    }
}
