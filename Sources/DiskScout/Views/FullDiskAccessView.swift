import SwiftUI
import AppKit

/// Step-by-step guide for granting Full Disk Access. macOS never switches an app on by itself,
/// so this sheet opens the right pane, helps the user find (or add) DiskScout in the list,
/// watches for the grant to land, and offers a one-click relaunch.
struct FullDiskAccessGuide: View {
    @EnvironmentObject var model: AppModel
    @State private var opened = false
    @State private var pulse = false

    private var granted: Bool { model.hasFullDiskAccess }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                status
                step(1, title: "Open the Full Disk Access list",
                     detail: "System Settings ▸ Privacy & Security ▸ Full Disk Access.",
                     done: opened || granted) {
                    Button(opened ? "Open Again" : "Open System Settings") {
                        opened = true
                        model.openFullDiskAccessPane()
                    }
                    .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color, prominent: !opened && !granted))
                }
                step(2, title: "Turn on the switch next to DiskScout",
                     detail: "If you've run different builds there may be more than one entry — turn on the one with the DiskScout icon. If DiskScout isn't listed, click + at the bottom of the list and choose it, or drag it in from Finder.",
                     done: granted) {
                    Button("Reveal DiskScout in Finder") { model.revealSelf() }
                        .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color, prominent: false))
                }
                step(3, title: "Quit and reopen DiskScout",
                     detail: "macOS applies the change when DiskScout starts again. One click does both.",
                     done: false) {
                    Button("Relaunch DiskScout") { model.relaunch() }
                        .buttonStyle(PillButtonStyle(color: granted ? SafetyLevel.safe.color : SafetyLevel.caution.color, prominent: granted))
                }
            }
            .padding(18)
            Divider()
            HStack(spacing: 10) {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Without it, macOS hides Mail, Messages, Safari and other apps' data from DiskScout and refuses to move their folders to the Trash.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(granted ? "Done" : "Later") { model.showFullDiskAccessGuide = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .frame(width: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .task {
            // Poll while the sheet is up so the status flips the moment the switch is turned on.
            while !Task.isCancelled {
                model.refreshFullDiskAccess()
                try? await Task.sleep(nanoseconds: 1_200_000_000)
            }
        }
        .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { pulse = true } }
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill((granted ? SafetyLevel.safe.color : SafetyLevel.caution.color).opacity(0.14)).frame(width: 46, height: 46)
                Image(systemName: granted ? "checkmark.shield.fill" : "lock.open.fill")
                    .font(.system(size: 20)).foregroundStyle(granted ? SafetyLevel.safe.color : SafetyLevel.caution.color)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Give DiskScout Full Disk Access").font(.system(size: 16, weight: .bold))
                Text("Takes about twenty seconds. DiskScout only ever reads sizes and moves what you approve to the Trash.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(18)
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle().fill(granted ? SafetyLevel.safe.color : SafetyLevel.caution.color)
                .frame(width: 8, height: 8)
                .scaleEffect(granted ? 1 : (pulse ? 1.25 : 0.8))
            Text(granted ? "Access granted — relaunch DiskScout so every part of the app picks it up."
                         : "Not granted yet. Waiting for the switch to be turned on…")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(granted ? SafetyLevel.safe.color : SafetyLevel.caution.color)
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((granted ? SafetyLevel.safe.color : SafetyLevel.caution.color).opacity(0.1)))
        .animation(.snappyUI, value: granted)
    }

    private func step<Action: View>(_ n: Int, title: String, detail: String, done: Bool, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? SafetyLevel.safe.color : Color.primary.opacity(0.08)).frame(width: 26, height: 26)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.system(size: 12, weight: .bold)).foregroundStyle(.secondary)
                }
            }
            .animation(.snappyUI, value: done)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                action().padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
    }
}
