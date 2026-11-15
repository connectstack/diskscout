import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The device's "Messages & Notes" tab: an access map, conversations (WhatsApp, Messages,
// Instagram), Notes, Calls, Safari and search. Data comes from an explicit source the user picks:
// this Mac's own synced copies, or an iPhone backup. Nothing switches to a backup on its own.

/// The tab inside a connected iPhone's view. Shares the app's one session, tied to that device.
struct DeviceBackupTab: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var device: IOSDevice
    var body: some View {
        BackupTabContent(device: device, session: model.personalData)
            .task(id: device.id) { model.personalData.setDevice(device.id) }
    }
}

/// The same view on its own, from the sidebar. Works with no iPhone attached.
struct PersonalDataView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var devices: DeviceMonitor = AppModel.shared.devices
    var body: some View {
        let device = devices.devices.first { $0.isReady }
        BackupTabContent(device: device, session: model.personalData)
            .task(id: device?.id) { model.personalData.setDevice(device?.id) }
    }
}

private struct BackupTabContent: View {
    @EnvironmentObject var model: AppModel
    let device: IOSDevice?
    @ObservedObject var session: BackupSession
    @State private var showUnlock = false

    private var searching: Bool { !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty }
    private var deviceName: String { device?.displayName ?? session.current?.deviceName ?? "your iPhone" }

    var body: some View {
        VStack(spacing: 0) {
            statusBar
            Divider()
            sectionPicker
            Divider()
            Group {
                if searching {
                    SearchResultsSection(session: session)
                } else {
                    switch session.section {
                    case .access: AccessMapSection(device: device, session: session)
                    case .instagram: InstagramSection(session: session)
                    default: sourceContent
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            session.appNames = Dictionary((device?.apps ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            await session.start()
        }
        .onChange(of: session.section) { _, s in session.load(s) }
        .sheet(isPresented: $showUnlock) { BackupUnlockSheet(session: session) }
    }

    // MARK: Status

    private var statusBar: some View {
        HStack(spacing: 10) {
            Picker("Source", selection: Binding(get: { session.sourceKind }, set: { k in Task { await session.switchSource(to: k) } })) {
                ForEach(BackupSession.SourceKind.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help("This Mac: copies iCloud and the apps keep here, no backup needed. iPhone backup: only when you choose it.")
            if session.sourceKind == .mac {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text("Copies already on this Mac").font(.system(size: 12, weight: .semibold))
                        if session.isLive {
                            Circle().fill(SafetyLevel.safe.color).frame(width: 6, height: 6)
                            Text("Live").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(SafetyLevel.safe.color)
                                .help("DiskScout re-reads a section a few seconds after new messages, notes or calls arrive on this Mac.")
                        }
                    }
                    Text("Synced by iCloud and the apps · no backup or cable needed").font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else if let b = session.current {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Backup from \(b.date.map { DateFormat.string($0) } ?? "an unknown date")").font(.system(size: 12, weight: .semibold))
                    Text(b.isEncrypted ? "Encrypted · everything is included" : "Not encrypted · call history and Safari history aren't included")
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
            } else {
                Text("No backup yet").font(.system(size: 12, weight: .semibold))
            }
            Spacer()
            if session.isIndexing {
                ProgressView().controlSize(.mini)
                Text("Indexing for search…").font(.system(size: 10.5)).foregroundStyle(.secondary)
            } else if session.indexedCount > 0 {
                Text("\(session.indexedCount.formatted()) items searchable").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .help("The search index is kept in memory only and disappears when you close this.")
            }
            if session.phase == .unlocking {
                ProgressView().controlSize(.small)
                Text("Unlocking…").font(.system(size: 11)).foregroundStyle(.secondary)
            } else if session.isOpen {
                if session.sourceKind == .backup, session.current?.isEncrypted == true {
                    Button { session.close() } label: { Label("Lock", systemImage: "lock") }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Close the backup and delete every decrypted copy")
                }
            } else if case .ready(let b) = session.phase, b.isComplete {
                Button { if b.isEncrypted { showUnlock = true } else { Task { await session.open(password: nil) } } } label: {
                    Label(b.isEncrypted ? "Unlock…" : "Open", systemImage: b.isEncrypted ? "lock.open" : "folder")
                }
                .buttonStyle(.borderedProminent).controlSize(.small).tint(DevicePalette.device)
            }
            Button { Task { await session.reload() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .help(session.sourceKind == .mac ? "Read again now" : "Look for a newer backup")
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private var sectionPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(BackupSession.Section.allCases) { s in
                        let selected = session.section == s && !searching
                        Button {
                            model.searchText = ""
                            withAnimation(.snappyUI) { session.section = s }
                        } label: {
                            Label(s.rawValue, systemImage: s.systemImage)
                                .font(.system(size: 12, weight: selected ? .semibold : .medium))
                                .padding(.horizontal, 11).padding(.vertical, 5)
                                .foregroundStyle(selected ? Color.white : Color.primary)
                                .background(Capsule().fill(selected ? (s.service?.color ?? DevicePalette.device) : Theme.subtleFill))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !searching, session.section != .access {
                let p = session.provenance(for: session.section)
                HStack(spacing: 8) {
                    ProvenanceBadge(label: p.label, level: p.level).help(p.detail)
                    if let note = session.sourceNote(for: session.section) {
                        Text(note).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    // MARK: Sections that need the chosen source

    @ViewBuilder
    private var sourceContent: some View {
        switch session.phase {
        case .idle:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .noAccess:
            EmptyState(systemImage: "lock.shield.fill", title: "DiskScout needs Full Disk Access",
                       message: session.sourceKind == .mac
                        ? "macOS keeps WhatsApp, Messages, Notes, call history and Safari private to their apps. Give DiskScout Full Disk Access to read them. Nothing leaves this Mac."
                        : "macOS keeps iPhone backups private to Finder. Give DiskScout Full Disk Access to read the backup of \(deviceName). Nothing leaves this Mac.",
                       tint: SafetyLevel.caution.color, action: ("Grant Full Disk Access…", { model.openFullDiskAccessSettings() }))
        case .none:
            NoBackupView(deviceName: deviceName) { session.refresh() }
        case .failed(let message):
            EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't read the data", message: message,
                       tint: SafetyLevel.caution.color, action: ("Try Again", { Task { await session.reload() } }))
        case .ready(let b):
            if !b.isComplete {
                EmptyState(systemImage: "hourglass", title: "The backup isn't finished",
                           message: "Finder is still backing up \(deviceName), or the last backup stopped part-way. Wait for it to finish, then look again.",
                           tint: .secondary, action: ("Look Again", { session.refresh() }))
            } else {
                EmptyState(systemImage: "lock.fill", title: "Unlock the backup",
                           message: "This backup is encrypted. Enter the password you chose in Finder. It never leaves this Mac.",
                           tint: DevicePalette.device, action: ("Unlock…", { showUnlock = true }))
            }
        case .unlocking:
            VStack(spacing: 12) {
                ProgressView()
                Text("Unlocking the backup…").font(.callout).foregroundStyle(.secondary)
                Text("Apple's encryption takes a few seconds on purpose.").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .open:
            Group {
                switch session.section {
                case .whatsapp: ConversationsSection(session: session, service: .whatsapp)
                case .messages: ConversationsSection(session: session, service: .messages)
                case .notes: NotesSection(session: session)
                case .calls: CallsSection(session: session)
                case .safari: SafariSection(session: session)
                case .access, .instagram: EmptyView()
                }
            }
            .onAppear { session.load(session.section) }
        }
    }
}

struct ProvenanceBadge: View {
    let label: String
    let level: AccessLevel
    var body: some View {
        Label(label, systemImage: level.systemImage)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(level.color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(level.color.opacity(0.14)))
            .fixedSize()
    }
}

// MARK: - Access map

/// Every kind of data, and the three ways it can (or can't) be reached. This is the honest picture:
/// what's live from the iPhone, what this Mac already has, what only a backup holds, what iOS blocks.
private struct AccessMapSection: View {
    @EnvironmentObject var model: AppModel
    let device: IOSDevice?
    @ObservedObject var session: BackupSession

    /// A "live from the iPhone" cell: opens that tab when a phone is connected.
    private func live(_ tab: DeviceTab) -> Cell {
        guard let device else { return Cell(state: .setup, text: "Connect the iPhone") }
        return Cell(state: .yes, text: "Live") { model.select(device: device); device.tab = tab }
    }

    struct Cell {
        enum State { case yes, setup, blocked, none }
        var state: State
        var text: String
        var level: AccessLevel = .direct
        var action: (() -> Void)? = nil
    }

    struct Row: Identifiable {
        let id: String
        let icon: String
        let title: String
        let detail: String
        let iphone: Cell
        let mac: Cell
        let backup: Cell
    }

    private func macCell(_ item: PersonalDataItem, _ section: BackupSession.Section, missing: String) -> Cell {
        guard let has = session.macHas else { return Cell(state: .none, text: "Checking…") }
        if has[item] == true {
            return Cell(state: .yes, text: "On this Mac", level: .onThisMac) {
                Task { await session.switchSource(to: .mac); session.section = section; session.load(section) }
            }
        }
        return Cell(state: .setup, text: missing, level: .onThisMac)
    }

    private func backupCell(_ section: BackupSession.Section, note: String? = nil) -> Cell {
        if let b = session.backups.first, b.isComplete {
            let when = b.date.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "backup"
            return Cell(state: .yes, text: note ?? "In backup of \(when)", level: .backupOnly) {
                Task { await session.switchSource(to: .backup); session.section = section; session.load(section) }
            }
        }
        return Cell(state: .setup, text: note.map { "\($0) · no backup yet" } ?? "No backup yet", level: .backupOnly)
    }

    private var rows: [Row] {
        let blocked = Cell(state: .blocked, text: "Blocked by iOS", level: .restricted)
        let dash = Cell(state: .none, text: "—")
        let instagram = session.conversation(.instagram).value != nil
        return [
            Row(id: "photos", icon: "photo.on.rectangle.angled", title: "Photos & videos", detail: "Camera roll, with which app saved each item",
                iphone: live(.photos), mac: dash, backup: dash),
            Row(id: "files", icon: "folder.fill", title: "Files", detail: "Media area and apps' shared Documents",
                iphone: live(.files), mac: dash, backup: dash),
            Row(id: "apps", icon: "square.grid.3x3.fill", title: "Apps & storage", detail: "Sizes, shared groups, iCloud, what stays after deleting",
                iphone: live(.overview), mac: dash, backup: dash),
            Row(id: "logs", icon: "doc.text.magnifyingglass", title: "Crash & diagnostic logs", detail: "Read and delete",
                iphone: live(.logs), mac: dash, backup: dash),
            Row(id: "whatsapp", icon: MessagingService.whatsapp.systemImage, title: "WhatsApp chats", detail: "Messages and media",
                iphone: blocked, mac: macCell(.whatsapp, .whatsapp, missing: "WhatsApp for Mac not linked"), backup: backupCell(.whatsapp)),
            Row(id: "messages", icon: MessagingService.messages.systemImage, title: "Messages", detail: "iMessage and SMS",
                iphone: blocked, mac: macCell(.messages, .messages, missing: "Messages not set up"), backup: backupCell(.messages)),
            Row(id: "notes", icon: "note.text", title: "Notes", detail: "iCloud notes; “On My iPhone” notes need a backup",
                iphone: blocked, mac: macCell(.notes, .notes, missing: "Notes not set up"), backup: backupCell(.notes)),
            Row(id: "calls", icon: "phone.fill", title: "Call history", detail: "Phone, FaceTime and app calls",
                iphone: blocked, mac: macCell(.calls, .calls, missing: "No calls synced"), backup: backupCell(.calls, note: "Encrypted backups only")),
            Row(id: "safari", icon: "safari.fill", title: "Safari", detail: "Bookmarks and history",
                iphone: blocked, mac: macCell(.safari, .safari, missing: "Safari not synced"), backup: backupCell(.safari)),
            Row(id: "instagram", icon: MessagingService.instagram.systemImage, title: "Instagram messages", detail: "Kept on Instagram's servers",
                iphone: blocked,
                mac: Cell(state: instagram ? .yes : .setup, text: instagram ? "Export opened" : "Import Instagram's export", level: .export) { session.section = .instagram },
                backup: Cell(state: .none, text: "Not supported")),
            Row(id: "private", icon: "lock.app.dashed", title: "Apps' private folders", detail: "Caches and databases of other apps",
                iphone: blocked, mac: dash, backup: Cell(state: .none, text: "Not shown")),
            Row(id: "secrets", icon: "key.fill", title: "Passwords & Health", detail: "Keychain and Health data",
                iphone: blocked, mac: dash, backup: Cell(state: .none, text: "Not supported")),
        ]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Where each kind of data can be read from").font(.system(size: 15, weight: .bold))
                    Text("DiskScout reads live from the iPhone wherever iOS allows it. For everything else it uses the copy this Mac already has, and it only opens an iPhone backup when you choose that source yourself.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    FlowLegend()
                }
                .card(padding: 14)

                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Data").frame(maxWidth: .infinity, alignment: .leading)
                        header("iPhone, live", .direct)
                        header("This Mac", .onThisMac)
                        header("iPhone backup", .backupOnly)
                    }
                    .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 6)
                    ForEach(rows) { row in
                        Divider()
                        HStack(spacing: 10) {
                            Image(systemName: row.icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(DevicePalette.device).frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.title).font(.system(size: 12.5, weight: .semibold))
                                Text(row.detail).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            cell(row.iphone)
                            cell(row.mac)
                            cell(row.backup)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                    }
                }
                .card(padding: 8)
            }
            .padding(16)
        }
        .onAppear { session.refreshAvailability() }
    }

    private func header(_ title: String, _ level: AccessLevel) -> some View {
        Label(title, systemImage: level.systemImage).foregroundStyle(level.color).frame(width: 170, alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ c: Cell) -> some View {
        let content = HStack(spacing: 5) {
            switch c.state {
            case .yes: Image(systemName: "checkmark.circle.fill").foregroundStyle(c.level.color)
            case .setup: Image(systemName: "circle.dashed").foregroundStyle(.secondary)
            case .blocked: Image(systemName: "lock.fill").foregroundStyle(AccessLevel.restricted.color.opacity(0.8))
            case .none: EmptyView()
            }
            Text(c.text).font(.system(size: 11, weight: c.state == .yes ? .semibold : .regular))
                .foregroundStyle(c.state == .yes ? Color.primary : Color.secondary).lineLimit(2)
            if c.action != nil, c.state != .none {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.tertiary)
            }
        }
        .frame(width: 170, alignment: .leading)
        if let action = c.action, c.state != .none {
            Button(action: { model.searchText = ""; action() }) { content.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

private struct FlowLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(AccessLevel.allCases, id: \.self) { level in
                HStack(spacing: 8) {
                    ProvenanceBadge(label: level.rawValue.uppercased(), level: level).frame(width: 150, alignment: .leading)
                    Text(level.meaning).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Search

private struct SearchResultsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession
    @State private var hits: [SearchIndex.Hit] = []
    @State private var searched = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                Text(searched == model.searchText ? "\(hits.count.formatted())\(hits.count >= 300 ? "+" : "") result\(hits.count == 1 ? "" : "s")" : "Searching…")
                    .font(.system(size: 12, weight: .semibold))
                Text("across \(session.indexedCount.formatted()) messages, notes, calls and pages").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("from:alex  in:whatsapp  after:2026-01-01  \"exact words\"")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                    .help("Narrow a search: from:name, in:whatsapp / messages / instagram / notes / calls / safari, before: and after: dates, and quotes for exact words.")
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if hits.isEmpty && searched == model.searchText {
                EmptyState(systemImage: "magnifyingglass", title: "No matches",
                           message: session.isIndexing ? "Still indexing. Results will fill in as sections finish loading." : "Nothing in the loaded data matches. Search covers the source you've chosen above.",
                           tint: .secondary)
            } else {
                List(hits) { hit in
                    Button { model.searchText = ""; session.open(hit) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: icon(hit)).foregroundStyle(hit.service?.color ?? DevicePalette.device).frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(hit.title.isEmpty ? label(hit) : hit.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(hit.date.map { DateFormat.string($0) } ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                Text(Self.highlight(hit.snippet)).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
        .task(id: model.searchText + "|\(session.indexedCount)") {
            let q = model.searchText
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }
            let found = await session.search(q)
            guard !Task.isCancelled else { return }
            hits = found
            searched = q
        }
    }

    private func icon(_ h: SearchIndex.Hit) -> String {
        switch h.kind {
        case .message: return h.service?.systemImage ?? "message"
        case .note: return "note.text"
        case .call: return "phone.fill"
        case .visit: return "clock"
        case .bookmark: return "bookmark.fill"
        }
    }

    private func label(_ h: SearchIndex.Hit) -> String {
        switch h.kind {
        case .message: return h.service?.rawValue ?? "Message"
        case .note: return "Note"
        case .call: return "Call"
        case .visit: return "Safari history"
        case .bookmark: return "Bookmark"
        }
    }

    /// Bolds the parts of a snippet the index marked as matches.
    static func highlight(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        var current = ""
        func flush() {
            guard !current.isEmpty else { return }
            var part = AttributedString(current)
            if bold { part.font = .system(size: 11.5, weight: .bold); part.foregroundColor = .primary }
            out += part
            current = ""
        }
        for ch in snippet {
            if ch == "\u{2}" { flush(); bold = true } else if ch == "\u{3}" { flush(); bold = false } else { current.append(ch == "\n" ? " " : ch) }
        }
        flush()
        return out
    }
}

private struct NoBackupView: View {
    let deviceName: String
    let lookAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(systemImage: "externaldrive.badge.timemachine", color: DevicePalette.device, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No backup of \(deviceName) on this Mac yet").font(.system(size: 15, weight: .semibold))
                    Text("WhatsApp chats, notes, call history and Safari live inside the iPhone where no Mac app can reach them. A backup made by Finder holds a copy DiskScout can read.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open Finder and click \(deviceName) in the sidebar.")
                step(2, "In General, choose “Back up all of the data on your iPhone to this Mac”.")
                step(3, "Tick “Encrypt local backup” and choose a password. Call history and Safari history are only included when it's encrypted.")
                step(4, "Click Back Up Now and keep the iPhone connected until it finishes.")
            }
            Button("Look Again", action: lookAgain).buttonStyle(PillButtonStyle(color: DevicePalette.device))
        }
        .card(padding: 18)
        .frame(maxWidth: 620)
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(DevicePalette.device))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct BackupUnlockSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BackupSession
    @State private var password = ""
    @State private var remember = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(systemImage: "lock.fill", color: DevicePalette.device, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Unlock the backup").font(.system(size: 15, weight: .bold))
                    Text("Enter the password you chose for encrypted backups in Finder.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            SecureField("Backup password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit { unlock() }
                .disabled(working)
            Toggle("Remember in my Keychain", isOn: $remember)
                .toggleStyle(.checkbox).font(.system(size: 12)).disabled(working)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5)).foregroundStyle(SafetyLevel.caution.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("The password stays on this Mac. Decrypted data lives in a private temporary folder and is deleted when you lock the backup or quit DiskScout.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                    Text("Unlocking… this takes a few seconds").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(working)
                Button("Unlock") { unlock() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(DevicePalette.device)
                    .disabled(password.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func unlock() {
        guard !password.isEmpty, !working else { return }
        working = true
        error = nil
        Task {
            let message = await session.open(password: password, remember: remember)
            working = false
            if let message { error = message } else { password = ""; dismiss() }
        }
    }
}

// MARK: - Shared

enum Exporter {
    /// Asks where to save, then writes the text. Returns the file written, or nil.
    @MainActor @discardableResult
    static func save(_ text: String, suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return url
        } catch {
            NSAlert(error: error).runModal()
            return nil
        }
    }

    static func fileName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n")).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Untitled" : cleaned).prefix(80))
    }
}

private struct SectionState<T, Content: View>: View {
    let loadable: BackupSession.Loadable<T>
    let what: String
    @ViewBuilder let content: (T) -> Content

    var body: some View {
        if let v = loadable.value {
            content(v)
        } else if loadable.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading \(what) from the backup…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let missing = loadable.missing {
            EmptyState(systemImage: "tray", title: "Nothing to show", message: missing, tint: .secondary)
        } else if let error = loadable.error {
            EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't read \(what)", message: error, tint: SafetyLevel.caution.color)
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private func shortDate(_ d: Date?) -> String {
    guard let d else { return "" }
    if Calendar.current.isDateInToday(d) { return d.formatted(date: .omitted, time: .shortened) }
    if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
    return d.formatted(date: .abbreviated, time: .omitted)
}

private struct Avatar: View {
    let name: String
    let isGroup: Bool
    var color: Color = Color(red: 0.18, green: 0.75, blue: 0.45)
    var size: CGFloat = 32
    var body: some View {
        let initials = name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        ZStack {
            Circle().fill(LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .top, endPoint: .bottom))
            if isGroup || initials.isEmpty || initials.first == "+" {
                Image(systemName: isGroup ? "person.3.fill" : "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.white)
            } else {
                Text(initials).font(.system(size: size * 0.38, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Conversations (WhatsApp, Messages, Instagram)

private struct ConversationsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession
    let service: MessagingService
    @State private var sort: Sort = .recent

    enum Sort: String, CaseIterable, Identifiable { case recent = "Recent", media = "Media size", messages = "Messages"; var id: String { rawValue } }

    var body: some View {
        SectionState(loadable: session.conversation(service), what: "\(service.rawValue) conversations") { data in
            let threads = sorted(data.threads)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(data.threads.count.formatted()) conversations · \(data.threads.reduce(0) { $0 + $1.mediaBytes }.bytesString) of media")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Picker("Sort", selection: $sort) { ForEach(Sort.allCases) { Text($0.rawValue).tag($0) } }
                            .pickerStyle(.menu).labelsHidden().controlSize(.small).fixedSize()
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    List(threads, selection: Binding(get: { session.selectedThread[service] }, set: { session.selectedThread[service] = $0; session.focusMessage = nil })) { t in
                        HStack(spacing: 9) {
                            Avatar(name: t.title, isGroup: t.isGroup, color: service.color)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(t.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                                    Spacer()
                                    Text(shortDate(t.lastDate)).font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                                HStack(spacing: 4) {
                                    Text("\(t.messageCount.formatted()) message\(t.messageCount == 1 ? "" : "s")")
                                    if t.mediaBytes > 0 {
                                        Text("·")
                                        Text(t.mediaBytes.bytesString).foregroundStyle(SizeTier(t.mediaBytes).color)
                                    }
                                    if t.archived { Image(systemName: "archivebox").help("Archived") }
                                }
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(t.id)
                    }
                    .listStyle(.inset)
                }
                .frame(width: 300)
                Divider()
                if let id = session.selectedThread[service], let thread = data.threads.first(where: { $0.id == id }) {
                    ChatView(session: session, store: data.store, thread: thread).id(thread.id)
                } else {
                    EmptyState(systemImage: service.systemImage, title: service.rawValue,
                               message: "Choose a conversation to read it. Sort by media size to see which ones hold the most photos and videos.", tint: .secondary)
                }
            }
        }
    }

    private func sorted(_ threads: [ChatThread]) -> [ChatThread] {
        var list = threads
        switch sort {
        case .recent: break
        case .media: list.sort { $0.mediaBytes > $1.mediaBytes }
        case .messages: list.sort { $0.messageCount > $1.messageCount }
        }
        return list
    }
}

private struct ChatView: View {
    @ObservedObject var session: BackupSession
    let store: ConversationStore
    let thread: ChatThread
    @State private var messages: [ChatMessage]?
    @State private var error: String?
    private static let pageSize = 2000

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Avatar(name: thread.title, isGroup: thread.isGroup, color: thread.service.color, size: 28)
                VStack(alignment: .leading, spacing: 0) {
                    Text(thread.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text([thread.detail, "\(thread.messageCount.formatted()) messages", thread.mediaCount > 0 ? "\(thread.mediaCount.formatted()) attachment\(thread.mediaCount == 1 ? "" : "s") · \(thread.mediaBytes.bytesString)" : nil]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { export() } label: { Label("Export…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(messages == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if let messages {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            if messages.count >= Self.pageSize, session.focusMessage == nil {
                                Text("Showing the latest \(Self.pageSize.formatted()) messages. Export the conversation for everything.")
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                            }
                            ForEach(Array(messages.enumerated()), id: \.element.id) { i, m in
                                if i == 0 || !Calendar.current.isDate(m.date ?? .distantPast, inSameDayAs: messages[i - 1].date ?? .distantPast) {
                                    Text(m.date?.formatted(date: .complete, time: .omitted) ?? "")
                                        .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary)
                                        .padding(.horizontal, 10).padding(.vertical, 3)
                                        .background(Capsule().fill(Theme.subtleFill))
                                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                                }
                                Bubble(store: store, message: m, showSender: thread.isGroup, tint: thread.service.color,
                                       highlighted: session.focusMessage == m.id).id(m.id)
                            }
                        }
                        .padding(14)
                    }
                    .onAppear { scroll(proxy, messages) }
                    .onChange(of: messages.count) { _, _ in scroll(proxy, messages) }
                    .onChange(of: session.focusMessage) { _, _ in scroll(proxy, messages) }
                }
            } else if let error {
                EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't read this conversation", message: error, tint: SafetyLevel.caution.color)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Re-read when the data changes underneath (live refresh), or when search asks for one message
        // that may be older than the latest page.
        .task(id: "\(thread.id)|\(session.revision)|\(session.focusMessage ?? "")") {
            let store = store, id = thread.id
            let limit = session.focusMessage == nil ? Self.pageSize : 1_000_000
            do { messages = try await Task.detached { try store.messages(in: id, limit: limit) }.value } catch { self.error = error.localizedDescription }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, _ messages: [ChatMessage]) {
        if let focus = session.focusMessage, messages.contains(where: { $0.id == focus }) {
            proxy.scrollTo(focus, anchor: .center)
        } else if let last = messages.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }

    private func export() {
        let store = store, thread = thread
        Task {
            let all = (try? await Task.detached { try store.messages(in: thread.id, limit: 1_000_000) }.value) ?? messages ?? []
            Exporter.save(ChatTranscript.text(thread: thread, messages: all), suggestedName: "\(thread.service.rawValue) – \(Exporter.fileName(thread.title)).txt", type: .plainText)
        }
    }
}

private struct Bubble: View {
    let store: ConversationStore
    let message: ChatMessage
    let showSender: Bool
    let tint: Color
    let highlighted: Bool
    @State private var opening: ChatAttachment?

    var body: some View {
        if message.isSystem {
            Text(message.text ?? "Conversation event").font(.system(size: 10.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else {
            HStack {
                if message.fromMe { Spacer(minLength: 80) }
                VStack(alignment: .leading, spacing: 3) {
                    if showSender, !message.fromMe, let s = message.sender {
                        Text(s).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(tint)
                    }
                    ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, a in attachment(a) }
                    if let t = message.text, !t.isEmpty {
                        Text(t).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(message.date?.formatted(date: .omitted, time: .shortened) ?? "")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(message.fromMe ? tint.opacity(0.25) : Color.primary.opacity(0.09)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.accentColor, lineWidth: highlighted ? 2 : 0))
                .frame(maxWidth: 460, alignment: message.fromMe ? .trailing : .leading)
                if !message.fromMe { Spacer(minLength: 80) }
            }
        }
    }

    private func attachment(_ a: ChatAttachment) -> some View {
        HStack(spacing: 6) {
            Image(systemName: a.kind.systemImage).foregroundStyle(.secondary)
            Text(a.title ?? a.kind.label).font(.system(size: 11.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
            if a.size > 0 { Text(a.size.bytesString).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            if a.kind == .link, let t = a.title, let url = URL(string: t), url.scheme?.hasPrefix("http") == true {
                Link("Open", destination: url).font(.system(size: 11, weight: .semibold))
            } else if a.locator != nil {
                if opening == a { ProgressView().controlSize(.mini) } else {
                    Button("Open") {
                        opening = a
                        let store = store
                        Task {
                            let url = try? await Task.detached { try store.file(for: a) }.value
                            if let url { QuickLookController.shared.toggle([url]) } else { NSSound.beep() }
                            opening = nil
                        }
                    }
                    .buttonStyle(.link).font(.system(size: 11, weight: .semibold))
                    .help("Open in Quick Look (the app may not have kept every file)")
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Instagram (official export)

private struct InstagramSection: View {
    @ObservedObject var session: BackupSession

    var body: some View {
        let state = session.conversation(.instagram)
        if state.value != nil {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Show", selection: $session.instagramPane) {
                        ForEach(BackupSession.InstagramPane.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().controlSize(.small).fixedSize()
                    .help("Messages, or everything else Instagram put in the export: contacts, followers, logins, ads, likes, searches and more")
                    Text(session.instagramExportPath.map { "Export: " + ($0 as NSString).lastPathComponent } ?? "").font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Open Another Export…") { choose() }.buttonStyle(.link).font(.system(size: 11))
                    Button("Forget") { session.forgetInstagramExport() }.buttonStyle(.link).font(.system(size: 11))
                }
                .padding(.horizontal, 14).padding(.vertical, 5)
                Divider()
                switch session.instagramPane {
                case .messages: ConversationsSection(session: session, service: .instagram)
                case .everything: InstagramExportBrowser(session: session)
                }
            }
        } else if state.loading {
            VStack(spacing: 10) {
                ProgressView()
                Text("Reading the Instagram export…").font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    IconTile(systemImage: MessagingService.instagram.systemImage, color: MessagingService.instagram.color, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Instagram messages come from Instagram's own export").font(.system(size: 15, weight: .semibold))
                        Text("Instagram keeps direct messages on its servers and in a private folder on the iPhone that no Mac app can open. The authorised way to get them is the copy Instagram gives you.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    step(1, "In Instagram: Settings ▸ Accounts Center ▸ Your information and permissions ▸ Download your information.")
                    step(2, "Choose Messages (or everything) and “Download to device”. Either format works, HTML or JSON.")
                    step(3, "When Instagram's email arrives, download the .zip to this Mac.")
                    step(4, "Open the .zip (or its unzipped folder) here.")
                }
                if let error = state.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 11.5)).foregroundStyle(SafetyLevel.caution.color)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Open Instagram Export…") { choose() }.buttonStyle(PillButtonStyle(color: MessagingService.instagram.color))
                    Text("Photos Instagram saved to your camera roll are already under Photos & Videos ▸ Saved by.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .card(padding: 18)
            .frame(maxWidth: 660)
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { session.load(.instagram) }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(MessagingService.instagram.color))
            Text(text).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.zip, .folder]
        panel.prompt = "Open Export"
        panel.message = "Choose the .zip Instagram sent you, or the folder it unzips to."
        if panel.runModal() == .OK, let url = panel.url { session.openInstagramExport(url) }
    }
}

// MARK: - Notes

private struct NotesSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession

    var body: some View {
        SectionState(loadable: session.notes, what: "notes") { data in
            let notes = data.notes.filter { model.searchText.isEmpty || $0.title.localizedCaseInsensitiveContains(model.searchText) || ($0.snippet ?? "").localizedCaseInsensitiveContains(model.searchText) }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack {
                        Text("\(data.notes.count.formatted()) notes").font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer()
                        Button("Export All…") { exportAll(data) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    Divider()
                    List(notes, selection: $session.selectedNote) { n in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                if n.isPinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(.orange) }
                                if n.isLocked { Image(systemName: "lock.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                                Text(n.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                            }
                            Text([shortDate(n.modified), n.inRecentlyDeleted ? "Recently Deleted" : n.folder].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                            if let s = n.snippet, !n.isLocked { Text(s).font(.system(size: 10.5)).foregroundStyle(.tertiary).lineLimit(1) }
                        }
                        .padding(.vertical, 2)
                        .tag(n.id)
                    }
                    .listStyle(.inset)
                }
                .frame(width: 300)
                Divider()
                if let id = session.selectedNote, let note = data.notes.first(where: { $0.id == id }) {
                    NoteBody(reader: data.reader, note: note).id(note.id)
                } else {
                    EmptyState(systemImage: "note.text", title: "Notes", message: "Choose a note to read it. Locked notes stay locked: they're encrypted with your Notes password.", tint: .secondary)
                }
            }
        }
    }

    private func exportAll(_ data: BackupSession.NotesData) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Each note is saved as a text file. Locked notes are skipped."
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let reader = data.reader, notes = data.notes
        Task {
            let written = await Task.detached { () -> Int in
                var used = Set<String>(), count = 0
                for n in notes where !n.isLocked {
                    guard let body = reader.body(of: n.id) else { continue }
                    var name = Exporter.fileName(n.title), i = 2
                    while used.contains(name.lowercased()) { name = "\(Exporter.fileName(n.title)) \(i)"; i += 1 }
                    used.insert(name.lowercased())
                    if (try? body.write(to: folder.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)) != nil { count += 1 }
                }
                return count
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([folder])
            if written == 0 { NSSound.beep() }
        }
    }
}

private struct NoteBody: View {
    let reader: NotesReader
    let note: NoteItem
    @State private var text: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 0) {
                    Text(note.title).font(.system(size: 13, weight: .semibold))
                    Text([note.folder, note.modified.map { "Edited " + DateFormat.string($0) }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                }
                Spacer()
                Button { if let text { Exporter.save(text, suggestedName: Exporter.fileName(note.title) + ".txt", type: .plainText) } } label: {
                    Label("Export…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered).controlSize(.small).disabled(text == nil)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if note.isLocked {
                EmptyState(systemImage: "lock.fill", title: "Locked note", message: "This note is encrypted with your Notes password, so it stays locked outside the Notes app.", tint: .secondary)
            } else if let text {
                ScrollView {
                    Text(text).font(.system(size: 13)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                }
            } else if loaded {
                EmptyState(systemImage: "doc.questionmark", title: "Couldn't read this note", message: "Its format isn't one DiskScout understands yet.", tint: .secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: note.id) {
            guard !note.isLocked else { return }
            let r = reader, id = note.id
            text = await Task.detached { r.body(of: id) }.value
            loaded = true
        }
    }
}

// MARK: - Calls

private struct CallsSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession
    @State private var filter: Filter = .all

    enum Filter: String, CaseIterable, Identifiable { case all = "All", missed = "Missed", incoming = "Incoming", outgoing = "Outgoing"; var id: String { rawValue } }

    var body: some View {
        SectionState(loadable: session.calls, what: "call history") { calls in
            let shown = filtered(calls)
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Text("\(shown.count.formatted()) calls · \(Self.duration(shown.reduce(0) { $0 + $1.duration })) talking")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button { Exporter.save(CallHistoryReader.csv(shown), suggestedName: "Call history.csv", type: .commaSeparatedText) } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                Divider()
                List(shown) { c in
                    HStack(spacing: 10) {
                        Image(systemName: c.missed ? "phone.arrow.down.left.fill" : (c.outgoing ? "phone.arrow.up.right.fill" : "phone.arrow.down.left"))
                            .foregroundStyle(c.missed ? SafetyLevel.protected.color : .secondary).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.name ?? c.number ?? "Unknown").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(c.missed ? SafetyLevel.protected.color : .primary)
                            Text([c.service, c.name == nil ? nil : c.number, c.location].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(c.duration > 0 ? Self.duration(c.duration) : c.direction).font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                        Text(c.date.map { DateFormat.string($0) } ?? "").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 150, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }
        }
    }

    private func filtered(_ calls: [CallRecord]) -> [CallRecord] {
        var list = calls
        switch filter {
        case .all: break
        case .missed: list = list.filter(\.missed)
        case .incoming: list = list.filter { !$0.outgoing && $0.answered }
        case .outgoing: list = list.filter(\.outgoing)
        }
        let q = model.searchText
        if !q.isEmpty { list = list.filter { ($0.name ?? "").localizedCaseInsensitiveContains(q) || ($0.number ?? "").contains(q) } }
        return list
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%dh %02dm", t / 3600, t / 60 % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

// MARK: - Safari

private struct SafariSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession
    @State private var showHistory = false
    @State private var otherDevicesOnly = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Show", selection: $showHistory) {
                    Text("Bookmarks").tag(false)
                    Text("History").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if showHistory, session.history.value?.contains(where: \.fromOtherDevice) == true {
                    Toggle("Only from iPhone & other devices", isOn: $otherDevicesOnly)
                        .toggleStyle(.checkbox).font(.system(size: 11.5))
                }
                Spacer()
                if showHistory, let h = session.history.value {
                    Button { Exporter.save(SafariReader.historyCSV(filteredHistory(h)), suggestedName: "Safari history.csv", type: .commaSeparatedText) } label: {
                        Label("Export CSV…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                } else if !showHistory, let b = session.bookmarks.value {
                    Button { Exporter.save(SafariReader.bookmarksHTML(b), suggestedName: "Safari bookmarks.html", type: .html) } label: {
                        Label("Export Bookmarks…", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    .help("Saves a bookmarks file Safari, Chrome and Firefox can import")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            if showHistory {
                SectionState(loadable: session.history, what: "Safari history") { visits in
                    List(filteredHistory(visits)) { v in
                        HStack(spacing: 10) {
                            Image(systemName: v.fromOtherDevice ? "iphone" : "clock").foregroundStyle(.secondary)
                                .help(v.fromOtherDevice ? "Visited on another device (synced through iCloud)" : "Visited on this device")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(v.title.flatMap { $0.isEmpty ? nil : $0 } ?? v.host).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(v.url).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            Text(v.date.map { DateFormat.string($0) } ?? "").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 1)
                    }
                    .listStyle(.inset)
                }
            } else {
                SectionState(loadable: session.bookmarks, what: "Safari bookmarks") { roots in
                    List(roots, children: \.children) { b in
                        HStack(spacing: 8) {
                            Image(systemName: b.isFolder ? (b.title == "Reading List" ? "eyeglasses" : "folder.fill") : "bookmark")
                                .foregroundStyle(b.isFolder ? DevicePalette.app : .secondary)
                            Text(b.title).font(.system(size: 12.5, weight: b.isFolder ? .semibold : .regular)).lineLimit(1)
                            if let u = b.url {
                                Text(u).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .onAppear { session.load(.safari) }
    }

    private func filteredHistory(_ visits: [SafariVisit]) -> [SafariVisit] {
        let q = model.searchText
        let scoped = otherDevicesOnly ? visits.filter(\.fromOtherDevice) : visits
        return q.isEmpty ? scoped : scoped.filter { ($0.title ?? "").localizedCaseInsensitiveContains(q) || $0.url.localizedCaseInsensitiveContains(q) }
    }
}

// MARK: - Inspector

struct BackupInspector: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        BackupInspectorContent(session: model.personalData)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
}

private struct BackupInspectorContent: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BackupSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Where this comes from").font(.system(size: 14, weight: .semibold))
                let p = session.provenance(for: session.section == .access ? .notes : session.section)
                if session.section != .access {
                    ProvenanceBadge(label: p.label, level: p.level)
                    Text(p.detail + ".").font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if session.sourceKind == .backup, let b = session.current {
                    DetailsGrid(rows: [
                        ("Device", b.deviceName),
                        ("Backed up", b.date.map { DateFormat.string($0) } ?? "—"),
                        ("iOS", b.productVersion ?? "—"),
                        ("Encrypted", b.isEncrypted ? "Yes" : "No"),
                        ("Status", b.isComplete ? (session.isOpen ? "Open" : "Locked") : "Not finished"),
                    ])
                    InspectorActions(actions: [.init(title: "Show in Finder", systemImage: "folder") { model.reveal([b.url]) }])
                    if session.hasRememberedPassword {
                        Button("Forget Saved Password") { session.forgetPassword() }.buttonStyle(.link).font(.system(size: 11.5))
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(AccessLevel.allCases, id: \.self) { level in
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: level.systemImage).font(.system(size: 10, weight: .semibold)).foregroundStyle(level.color).frame(width: 16)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(level.rawValue).font(.system(size: 11.5, weight: .semibold))
                                Text(level.meaning).font(.system(size: 10.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .card(padding: 10)
                Label("Everything is read on this Mac and never uploaded.", systemImage: "hand.raised.fill")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                Label("DiskScout reads private copies in a temporary folder and keeps the search index in memory. Both are gone when you close this, unplug the iPhone or quit.", systemImage: "trash")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
