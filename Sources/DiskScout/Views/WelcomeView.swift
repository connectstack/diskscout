import SwiftUI

struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var appeared = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.heroGradient
                VStack(spacing: 10) {
                    ZStack {
                        Circle().fill(.white.opacity(0.15)).frame(width: 74, height: 74)
                        Image(systemName: "internaldrive.fill")
                            .font(.system(size: 34, weight: .medium)).foregroundStyle(.white)
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold)).foregroundStyle(Color(red: 1, green: 0.85, blue: 0.4))
                            .offset(x: 26, y: -24)
                            .symbolEffect(.pulse, options: .repeating)
                    }
                    .scaleEffect(appeared ? 1 : 0.7)
                    Text("Know what's safe to delete.")
                        .font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                    Text("DiskScout finds what's eating your disk and tells you, in plain English, whether each item is junk, yours, or something apps still need.")
                        .font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .padding(.vertical, 30)
            }
            .frame(height: 220)

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(Array(SafetyLevel.allCases.enumerated()), id: \.element) { i, level in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Image(systemName: level.systemImage).foregroundStyle(level.color)
                                Text(level.shortTitle).font(.system(size: 12.5, weight: .bold))
                            }
                            Text(level.tagline).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(level.color.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(level.color.opacity(0.25)))
                        .opacity(appeared ? 1 : 0)
                        .offset(y: appeared ? 0 : 16)
                        .animation(.spring(duration: 0.6, bounce: 0.2).delay(0.15 + Double(i) * 0.08), value: appeared)
                    }
                }

                fullDiskAccess

                HStack {
                    Label("Everything goes to the Trash first — nothing is deleted permanently without asking.", systemImage: "arrow.uturn.backward.circle")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Start with Smart Clean") {
                        model.settings.hasSeenWelcome = true
                        model.showWelcome = false
                        model.select(location: QuickLocations.smartClean)
                    }
                    .buttonStyle(PillButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(22)
        }
        .frame(width: 680)
        .onAppear { withAnimation(.spring(duration: 0.7, bounce: 0.25)) { appeared = true } }
    }

    private var fullDiskAccess: some View {
        HStack(spacing: 12) {
            Image(systemName: model.hasFullDiskAccess ? "checkmark.shield.fill" : "lock.open.fill")
                .font(.system(size: 20))
                .foregroundStyle(model.hasFullDiskAccess ? SafetyLevel.safe.color : SafetyLevel.caution.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.hasFullDiskAccess ? "Full Disk Access is on" : "Grant Full Disk Access for complete results")
                    .font(.system(size: 12.5, weight: .semibold))
                Text(model.hasFullDiskAccess
                     ? "DiskScout can see everything, including Mail, Safari and app containers."
                     : "Without it macOS hides Mail, Messages, Safari and some app data, so sizes will be too small. DiskScout will walk you through it in three short steps.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !model.hasFullDiskAccess {
                Button("Open Settings") { model.openFullDiskAccessSettings() }
                    .buttonStyle(PillButtonStyle(color: SafetyLevel.caution.color, prominent: false))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.subtleFill))
    }
}
