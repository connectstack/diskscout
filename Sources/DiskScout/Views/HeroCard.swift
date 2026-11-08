import SwiftUI

struct HeroCard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine
    @ObservedObject var cleaner: CleanupScanner
    let info: DiskInfo?

    private var segments: [SegmentBar.Segment] {
        if model.mode == .smartClean || engine.root == nil {
            return cleaner.categoriesWithItems.map { c in
                SegmentBar.Segment(id: c.rawValue, value: Double(cleaner.total(in: c)), color: c.color, label: c.rawValue)
            }
        }
        return FileCategory.allCases.compactMap { c in
            guard let v = engine.categoryTotals[c], v > 0 else { return nil }
            return SegmentBar.Segment(id: c.rawValue, value: Double(v), color: c.color, label: c.rawValue)
        }.sorted { $0.value > $1.value }
    }

    private var breakdownTitle: String {
        if model.mode == .smartClean || engine.root == nil {
            return cleaner.items.isEmpty ? (cleaner.isScanning ? "Looking for junk…" : "Reclaimable space") : "Reclaimable space · \(cleaner.totalAll.bytesString)"
        }
        return "What's in \(engine.root?.name ?? "this folder") · \(engine.root?.size.bytesString ?? "")"
    }

    var body: some View {
        HStack(spacing: 18) {
            if let info {
                UsageRing(fraction: info.usedFraction, color: ringColor(info))
                    .frame(width: 86, height: 86)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(info.volumeName)
                            .font(.system(size: 15, weight: .semibold))
                        Text("\(info.used.bytesString) used of \(info.total.bytesString)")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .lineLimit(1)
                    HStack(spacing: 8) {
                        Label("\(info.freeForImportantUsage.bytesString) free", systemImage: "circle.dashed")
                        if info.purgeable > 50_000_000 {
                            Label("\(info.purgeable.bytesString) purgeable", systemImage: "wind")
                                .help("Space macOS can free on its own when needed (local snapshots, caches).")
                        }
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.7))
                    .labelStyle(.titleAndIcon)

                    Spacer(minLength: 6)
                    breakdown
                }
            } else {
                Text("Startup disk unavailable").foregroundStyle(.white.opacity(0.7))
            }

            Spacer(minLength: 12)
            sideStats
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(height: 138)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Theme.heroColors[1].opacity(0.35), radius: 14, y: 6)
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(breakdownTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .contentTransition(.opacity)
            SegmentBar(segments: segments, height: 9, emptyColor: .white.opacity(0.12))
            legend
        }
        .animation(.gentle, value: segments.map(\.id))
    }

    private var legend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(segments.prefix(5)) { s in
                    HStack(spacing: 4) {
                        Circle().fill(s.color).frame(width: 7, height: 7)
                        Text(s.label).font(.system(size: 10.5))
                        Text(Int64(s.value).bytesString).font(.system(size: 10.5, weight: .medium)).monospacedDigit().opacity(0.8)
                    }
                    .fixedSize()
                    .transition(.opacity.combined(with: .move(edge: .leading)))
                }
                if segments.isEmpty {
                    Text(model.mode == .smartClean ? "Smart Clean is sizing known junk locations." : "Scan a folder to see what's inside it.")
                        .font(.system(size: 10.5)).opacity(0.6)
                }
            }
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(1)
        }
        .frame(height: 16)
    }

    private var sideStats: some View {
        VStack(alignment: .trailing, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Safe to clean now")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    let parts = ByteFormat.parts(cleaner.totalSafe)
                    Text(parts.number)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(cleaner.totalSafe)))
                    Text(parts.unit)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .animation(.snappyUI, value: cleaner.totalSafe)
                .foregroundStyle(cleaner.totalSafe > 0 ? SafetyLevel.safe.color : .white)
            }
            if model.mode != .smartClean {
                Button {
                    model.select(location: QuickLocations.smartClean)
                } label: {
                    Label("Smart Clean", systemImage: "sparkles")
                }
                .buttonStyle(PillButtonStyle(color: Color(red: 0.74, green: 0.47, blue: 1.0)))
            } else if cleaner.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(.white)
                    Text(cleaner.currentCategory?.rawValue ?? "Scanning…")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.75))
                        .contentTransition(.opacity)
                }
            } else {
                Button {
                    cleaner.scan()
                } label: {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .buttonStyle(PillButtonStyle(color: .white.opacity(0.9), prominent: false))
            }
        }
        .frame(minWidth: 170, alignment: .trailing)
    }

    private var background: some View {
        ZStack {
            Theme.heroGradient
            Circle()
                .fill(Color(red: 0.74, green: 0.47, blue: 1.0).opacity(0.35))
                .frame(width: 260, height: 260)
                .blur(radius: 70)
                .offset(x: -220, y: 60)
            Circle()
                .fill(Color(red: 0.27, green: 0.72, blue: 0.95).opacity(0.35))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: 260, y: -70)
            LinearGradient(colors: [.white.opacity(0.08), .clear], startPoint: .top, endPoint: .center)
        }
    }

    private func ringColor(_ info: DiskInfo) -> Color {
        switch info.usedFraction {
        case 0.92...: return SafetyLevel.protected.color
        case 0.8...:  return SafetyLevel.caution.color
        case 0.6...:  return Color(red: 0.98, green: 0.80, blue: 0.25)
        default:      return SafetyLevel.safe.color
        }
    }
}

struct UsageRing: View {
    let fraction: Double
    let color: Color
    var lineWidth: CGFloat = 9
    @State private var animated: Double = 0

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.14), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: animated)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * max(animated, 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.5), radius: 6)
            VStack(spacing: 0) {
                Text("\(Int((animated * 100).rounded()))%")
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text("used")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .onAppear { withAnimation(.spring(duration: 1.3, bounce: 0.12)) { animated = fraction } }
        .onChange(of: fraction) { _, new in withAnimation(.spring(duration: 0.8)) { animated = new } }
    }
}

struct SegmentBar: View {
    struct Segment: Identifiable, Equatable {
        let id: String
        let value: Double
        let color: Color
        let label: String
    }
    let segments: [Segment]
    var height: CGFloat = 10
    var emptyColor: Color = Color.primary.opacity(0.08)
    private let spacing: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let total = segments.reduce(0.0) { $0 + $1.value }
            let visible = segments.filter { total > 0 && $0.value / total >= 0.012 }
            let available = geo.size.width - spacing * CGFloat(max(0, visible.count - 1))
            HStack(spacing: spacing) {
                if visible.isEmpty {
                    Capsule().fill(emptyColor)
                } else {
                    ForEach(visible) { s in
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(LinearGradient(colors: [s.color, s.color.opacity(0.8)], startPoint: .top, endPoint: .bottom))
                            .frame(width: max(3, available * CGFloat(s.value / total)))
                            .help("\(s.label): \(Int64(s.value).bytesString)")
                    }
                }
            }
            .animation(.gentle, value: segments)
        }
        .frame(height: height)
    }
}
