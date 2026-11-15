import SwiftUI
import AppKit

/// Shown before anything is moved to the Trash. Explains every item, requires an
/// explicit acknowledgement for Caution items, then performs the move with progress.
struct ReviewSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: TrashPlan

    @State private var acknowledgedCaution = false
    @State private var phase: Phase = .review
    @State private var progress: (done: Int, total: Int) = (0, 1)
    @State private var outcome: TrashOutcome?

    enum Phase { case review, working, done }

    var body: some View {
        VStack(spacing: 0) {
            switch phase {
            case .review: reviewBody
            case .working: workingBody
            case .done: doneBody
            }
        }
        .frame(width: 560)
        .frame(minHeight: 380, maxHeight: 640)
        .background(Color(nsColor: .windowBackgroundColor))
        #if DEBUG
        .task { if CommandLine.arguments.contains("--demo-review-run") { await run() } }
        #endif
    }

    // MARK: Review

    private var reviewBody: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(plan.deletable) { c in
                        CandidateRow(candidate: c)
                    }
                    if !plan.blocked.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("\(plan.blocked.count) protected item\(plan.blocked.count == 1 ? "" : "s") will be skipped", systemImage: "lock.shield.fill")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SafetyLevel.protected.color)
                            ForEach(plan.blocked) { b in
                                Text("• \(b.name) — \(b.assessment.explanation)").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(SafetyLevel.protected.color.opacity(0.08)))
                    }
                }
                .padding(16)
            }
            Divider()
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(SafetyLevel.protected.color.opacity(0.12)).frame(width: 46, height: 46)
                Image(systemName: "trash.fill").font(.system(size: 20)).foregroundStyle(SafetyLevel.protected.color)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(plan.includesEmptyTrash
                     ? (plan.deletable.count == 1 ? "Empty the Trash?" : "Move \(plan.deletable.count - 1) item\(plan.deletable.count == 2 ? "" : "s") to the Trash, then empty it?")
                     : "Move \(plan.deletable.count) item\(plan.deletable.count == 1 ? "" : "s") to the Trash?")
                    .font(.system(size: 16, weight: .bold))
                HStack(spacing: 8) {
                    Text("Frees \(plan.totalSize.bytesString)").font(.system(size: 12, weight: .semibold)).foregroundStyle(SafetyLevel.safe.color)
                    ForEach(SafetyLevel.allCases.filter { $0 != .protected }, id: \.self) { l in
                        if plan.count(l) > 0 {
                            HStack(spacing: 3) {
                                Image(systemName: l.systemImage).font(.system(size: 9, weight: .bold))
                                Text("\(plan.count(l)) \(l.shortTitle.lowercased())")
                            }
                            .font(.system(size: 11)).foregroundStyle(l.color)
                        }
                    }
                }
            }
            Spacer()
        }
        .padding(16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if plan.hasCaution {
                Toggle(isOn: $acknowledgedCaution) {
                    Text("I understand the Caution items may contain app data or settings that won't come back on their own.")
                        .font(.system(size: 11.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                .tint(SafetyLevel.caution.color)
            }
            HStack {
                Label(plan.includesEmptyTrash ? "Emptying the Trash is permanent." : "Items go to the Trash. You can put them back from the Trash or with Undo.", systemImage: plan.includesEmptyTrash ? "exclamationmark.triangle" : "arrow.uturn.backward")
                    .font(.system(size: 11)).foregroundStyle(plan.includesEmptyTrash ? SafetyLevel.caution.color : .secondary)
                Spacer()
                Button("Cancel") { model.dismissPlan() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
                Button {
                    Task { await run() }
                } label: {
                    Label(plan.includesEmptyTrash ? (plan.deletable.count == 1 ? "Empty Trash" : "Move & Empty Trash") : "Move to Trash", systemImage: "trash")
                }
                // Return confirms only what Undo can reverse. Emptying the Trash needs a click.
                .keyboardShortcut(plan.includesEmptyTrash ? nil : KeyboardShortcut.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(SafetyLevel.protected.color)
                .disabled(plan.deletable.isEmpty || (plan.hasCaution && !acknowledgedCaution))
            }
        }
        .padding(16)
    }

    // MARK: Working

    private var workingBody: some View {
        VStack(spacing: 18) {
            Spacer()
            ZStack {
                Circle().stroke(Color.primary.opacity(0.08), lineWidth: 8).frame(width: 90, height: 90)
                Circle()
                    .trim(from: 0, to: CGFloat(progress.done) / CGFloat(max(progress.total, 1)))
                    .stroke(SafetyLevel.safe.color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 90, height: 90)
                    .animation(.snappyUI, value: progress.done)
                Image(systemName: "trash").font(.system(size: 26)).foregroundStyle(.secondary)
            }
            Text("Moving to Trash…").font(.system(size: 15, weight: .semibold))
            Text("\(progress.done) of \(progress.total)").font(.callout.monospacedDigit()).foregroundStyle(.secondary).contentTransition(.numericText())
            Spacer()
        }
        .padding(30)
    }

    // MARK: Done

    private var doneBody: some View {
        VStack(spacing: 14) {
            Spacer()
            SuccessCheck(color: (outcome?.failed.isEmpty ?? true) ? SafetyLevel.safe.color : SafetyLevel.caution.color)
                .frame(width: 96, height: 96)
            VStack(spacing: 4) {
                Text(doneTitle).font(.system(size: 18, weight: .bold))
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("Freed")
                    Text((outcome?.freed ?? 0).bytesString).fontWeight(.bold).foregroundStyle(SafetyLevel.safe.color)
                }
                .font(.system(size: 14))
            }
            if let failed = outcome?.failed, !failed.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    if outcome?.anyPermissionFailure == true {
                        VStack(alignment: .leading, spacing: 6) {
                            Label("macOS protects other apps' data", systemImage: "lock.shield.fill")
                                .font(.system(size: 12, weight: .semibold)).foregroundStyle(SafetyLevel.caution.color)
                            Text("Apps without Full Disk Access can't move folders that belong to other apps, such as items in Library/Containers. Grant DiskScout Full Disk Access (then try again), or drag the item to the Trash in Finder.")
                                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Grant Full Disk Access…") { model.openFullDiskAccessSettings() }
                                    .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color))
                                Button("Show All in Finder") { model.reveal(failed.map(\.url)) }
                                    .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color, prominent: false))
                            }
                            .padding(.top, 2)
                        }
                        Divider()
                    }
                    ForEach(failed) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: f.url.path)).resizable().frame(width: 20, height: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                                Text(f.permission ? f.url.path : f.error).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                    .lineLimit(2).truncationMode(.middle)
                            }
                            Spacer()
                            Button("Show in Finder") { model.reveal([f.url]) }.buttonStyle(.bordered).controlSize(.small)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(SafetyLevel.caution.color.opacity(0.1)))
                .padding(.horizontal, 20)
                .padding(.vertical, 1)
                .modifier(ScrollIfTall())
            }
            Spacer()
            Button("Done") { if let outcome { model.finish(outcome) } else { model.dismissPlan() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(PillButtonStyle())
                .padding(.bottom, 18)
        }
        .padding(20)
    }

    private var doneTitle: String {
        guard let outcome else { return "Done" }
        if !outcome.failed.isEmpty { return "Finished with \(outcome.failed.count) problem\(outcome.failed.count == 1 ? "" : "s")" }
        if outcome.moved.isEmpty && outcome.emptiedTrash { return "Trash emptied" }
        return "Moved \(outcome.moved.count) item\(outcome.moved.count == 1 ? "" : "s") to Trash"
    }

    private func run() async {
        withAnimation(.snappyUI) { phase = .working }
        progress = (0, plan.deletable.count)
        let result = await model.perform(plan) { done, total in
            progress = (done, total)
        }
        outcome = result
        withAnimation(.spring(duration: 0.5, bounce: 0.3)) { phase = .done }
        // Auto-close quickly when everything went fine.
        if result.failed.isEmpty {
            try? await Task.sleep(nanoseconds: 1_400_000_000)
            if phase == .done { model.finish(result) }
        }
    }
}

private struct CandidateRow: View {
    let candidate: TrashCandidate
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(nsImage: candidate.icon).resizable().frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(candidate.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(candidate.assessment.headline).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                SafetyBadge(level: candidate.assessment.level)
                Text(candidate.size.bytesString).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().frame(width: 76, alignment: .trailing)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 0 : -90))
            }
            if expanded {
                Text(candidate.assessment.explanation)
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
                Text(candidate.url.path)
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(2).truncationMode(.middle)
                    .padding(.leading, 38)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(candidate.assessment.level.color.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(candidate.assessment.level.color.opacity(0.2)))
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(.snappyUI) { expanded.toggle() } }
    }
}

struct SuccessCheck: View {
    let color: Color
    @State private var drawn = false
    @State private var scale: CGFloat = 0.6

    var body: some View {
        ZStack {
            Circle().fill(color.opacity(0.15))
            Circle().stroke(color, lineWidth: 5).padding(6)
            Checkmark()
                .trim(from: 0, to: drawn ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                .padding(28)
        }
        .scaleEffect(scale)
        .onAppear {
            withAnimation(.spring(duration: 0.5, bounce: 0.45)) { scale = 1 }
            withAnimation(.easeOut(duration: 0.45).delay(0.15)) { drawn = true }
        }
    }

    struct Checkmark: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY - rect.height * 0.05))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + rect.height * 0.1))
            return p
        }
    }
}


/// Lets a long failure list scroll without pushing the Done button off the sheet.
private struct ScrollIfTall: ViewModifier {
    func body(content: Content) -> some View {
        ScrollView { content }.frame(maxHeight: 320)
    }
}
