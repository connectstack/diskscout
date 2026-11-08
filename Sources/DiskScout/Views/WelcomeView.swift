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

struct UpgradeView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var license: LicenseManager
    @State private var key = ""
    @State private var error: String?
    @State private var success = false
    @State private var activating = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Theme.heroGradient
                VStack(spacing: 8) {
                    Image(systemName: success ? "checkmark.seal.fill" : "sparkles")
                        .font(.system(size: 36, weight: .medium))
                        .foregroundStyle(success ? SafetyLevel.safe.color : Color(red: 1, green: 0.85, blue: 0.4))
                        .contentTransition(.symbolEffect(.replace))
                    Text(success ? "You're all set" : title).font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                    Text(success ? "Thanks for supporting DiskScout. Cleaning is unlocked on this Mac." : subtitle)
                        .font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center).frame(maxWidth: 400)
                }
                .padding(.vertical, 26)
            }
            .frame(height: 180)

            if !success {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        feature("checkmark.shield.fill", "Unlimited cleaning", "Move anything DiskScout rates Safe, Review or Caution to the Trash — with Undo.")
                        feature("sparkles", "Smart Clean", "One click selects everything that's safe. Leftover detection, dev caches, Xcode junk.")
                        feature("eye.fill", "Scan & preview stay free", "Browsing, treemap, previews and safety ratings never lock.")
                        feature("laptopcomputer.and.arrow.down", "One-time purchase", "\(LicenseManager.price) for all your Macs. Free updates for the 2.x series.")
                    }
                    HStack(spacing: 10) {
                        Button {
                            NSWorkspace.shared.open(LicenseManager.purchaseURL)
                        } label: {
                            Label("Buy DiskScout Pro — \(LicenseManager.price)", systemImage: "cart.fill")
                        }
                        .buttonStyle(PillButtonStyle())
                        Spacer()
                        if case .trial(let d) = license.status {
                            Text("\(d) trial day\(d == 1 ? "" : "s") left").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Already have a key?").font(.system(size: 12, weight: .semibold))
                        Text("Paste the license key from your Gumroad receipt, or the DS1 key you were sent.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            TextField("Gumroad key or DS1.… key", text: $key)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .onSubmit(activate)
                            Button(action: activate) {
                                if activating { ProgressView().controlSize(.small).frame(width: 52) } else { Text("Activate") }
                            }
                                .buttonStyle(.borderedProminent)
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || activating)
                        }
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(SafetyLevel.protected.color)
                                .transition(.opacity)
                        }
                    }
                    HStack {
                        Spacer()
                        Button(license.status == .expired ? "Not now" : "Continue trial") { model.showUpgrade = false }
                            .buttonStyle(.plain).foregroundStyle(.secondary).font(.system(size: 12))
                    }
                }
                .padding(22)
            } else {
                Button("Start cleaning") { model.showUpgrade = false }
                    .buttonStyle(PillButtonStyle())
                    .padding(24)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520)
        .animation(.snappyUI, value: success)
        .animation(.snappyUI, value: error)
    }

    private var title: String {
        license.status == .expired ? "Your free trial has ended" : "Unlock DiskScout Pro"
    }
    private var subtitle: String {
        license.status == .expired
            ? "You can still scan, browse and preview everything. Moving items to the Trash needs a license."
            : "Support an independent Mac app and keep cleaning after the trial."
    }

    private func feature(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12.5, weight: .semibold))
                Text(text).font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func activate() {
        guard !activating else { return }
        activating = true
        Task {
            let result = await license.activate(key)
            activating = false
            switch result {
            case .success:
                error = nil
                success = true
            case .failure(let e):
                error = e.localizedDescription
            }
        }
    }
}
