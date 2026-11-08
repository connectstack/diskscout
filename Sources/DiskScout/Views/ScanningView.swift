import SwiftUI

struct ScanningView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var engine: ScanEngine

    var body: some View {
        ScrollView {
            scanningBody
                .frame(maxWidth: .infinity)
        }
    }

    private var scanningBody: some View {
        VStack(spacing: 22) {
            Spacer(minLength: 10)
            Radar()
                .frame(width: 130, height: 130)
            VStack(spacing: 6) {
                Text("Scanning \(engine.scanTarget?.lastPathComponent.isEmpty == false ? engine.scanTarget!.lastPathComponent : "your Mac")…")
                    .font(.system(size: 18, weight: .semibold))
                HStack(spacing: 18) {
                    stat(value: engine.scannedItems.formatted(), label: "items")
                    stat(value: engine.scannedBytes.bytesString, label: "found")
                    stat(value: String(format: "%.1fs", engine.elapsed), label: "elapsed")
                }
                .padding(.top, 4)
            }
            discovered
            Button("Stop") { model.stop() }
                .buttonStyle(PillButtonStyle(color: .secondary, prominent: false))
            Spacer(minLength: 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func stat(value: String, label: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappyUI, value: value)
            Text(label).font(.system(size: 10.5)).foregroundStyle(.secondary)
        }
        .frame(minWidth: 80)
    }

    @ViewBuilder
    private var discovered: some View {
        let items = engine.discovered
        let maxSize = Double(items.first?.size ?? 1)
        VStack(alignment: .leading, spacing: 6) {
            if !items.isEmpty {
                Text("Found so far")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
            }
            ForEach(items.prefix(6)) { item in
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill").foregroundStyle(.tint).font(.system(size: 12))
                    Text(item.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1).frame(width: 170, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(Color.primary.opacity(0.07))
                            .overlay(alignment: .leading) {
                                Capsule()
                                    .fill(LinearGradient(colors: [Color.accentColor, Color.accentColor.opacity(0.6)], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, geo.size.width * CGFloat(Double(item.size) / max(maxSize, 1))))
                            }
                    }
                    .frame(height: 7)
                    Text(item.size.bytesString)
                        .font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit()
                        .frame(width: 76, alignment: .trailing)
                        .contentTransition(.numericText())
                }
                .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(width: 460)
        .animation(.spring(duration: 0.5, bounce: 0.15), value: items)
    }
}

/// Concentric pulsing rings with a rotating sweep.
struct Radar: View {
    @State private var rotate = false
    @State private var pulse = false

    var body: some View {
        ZStack {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(Color.accentColor.opacity(0.25 - Double(i) * 0.06), lineWidth: 1.5)
                    .scaleEffect(pulse ? 1.0 + Double(i) * 0.18 : 0.5 + Double(i) * 0.1)
                    .opacity(pulse ? 0 : 1)
                    .animation(.easeOut(duration: 2.2).repeatForever(autoreverses: false).delay(Double(i) * 0.5), value: pulse)
            }
            Circle()
                .fill(AngularGradient(colors: [Color.accentColor.opacity(0), Color.accentColor.opacity(0.0), Color.accentColor.opacity(0.55)], center: .center))
                .mask(Circle().strokeBorder(lineWidth: 60))
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(.linear(duration: 1.8).repeatForever(autoreverses: false), value: rotate)
            Circle()
                .fill(Theme.heroGradient)
                .frame(width: 58, height: 58)
                .shadow(color: Color.accentColor.opacity(0.5), radius: 12)
            Image(systemName: "internaldrive.fill")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.white)
                .symbolEffect(.pulse, options: .repeating)
        }
        .onAppear { rotate = true; pulse = true }
    }
}
