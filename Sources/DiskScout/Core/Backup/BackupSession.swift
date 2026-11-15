import Foundation
import AppKit
import SwiftUI

extension WhatsAppReader: @unchecked Sendable {}
extension NotesReader: @unchecked Sendable {}

/// Personal data for a device (WhatsApp, Messages, Instagram, Notes, Calls, Safari), read from
/// an explicit source: the copies already on this Mac, or the iPhone's newest backup. The source
/// only ever changes when the user switches it; nothing falls back to a backup on its own.
@MainActor
final class BackupSession: ObservableObject {
    enum SourceKind: String, CaseIterable, Identifiable {
        case mac = "This Mac"
        case backup = "iPhone backup"
        var id: String { rawValue }
    }

    enum Phase: Equatable {
        case idle
        case noAccess
        case none
        case ready(IOSBackupInfo)
        case unlocking
        case open
        case failed(String)
    }

    enum Section: String, CaseIterable, Identifiable {
        case access = "All Data", whatsapp = "WhatsApp", messages = "Messages", instagram = "Instagram"
        case notes = "Notes", calls = "Calls", safari = "Safari"
        var id: String { rawValue }
        var systemImage: String {
            switch self {
            case .access: return "square.grid.2x2.fill"
            case .whatsapp: return MessagingService.whatsapp.systemImage
            case .messages: return MessagingService.messages.systemImage
            case .instagram: return MessagingService.instagram.systemImage
            case .notes: return "note.text"
            case .calls: return "phone.fill"
            case .safari: return "safari.fill"
            }
        }
        var service: MessagingService? {
            switch self {
            case .whatsapp: return .whatsapp
            case .messages: return .messages
            case .instagram: return .instagram
            default: return nil
            }
        }
        init(_ service: MessagingService) {
            switch service {
            case .whatsapp: self = .whatsapp
            case .messages: self = .messages
            case .instagram: self = .instagram
            }
        }
    }

    struct Loadable<T> {
        var value: T?
        var loading = false
        var error: String?
        /// The source doesn't contain this data, and why.
        var missing: String?
    }

    struct ConversationData {
        let store: ConversationStore
        let threads: [ChatThread]
    }

    struct NotesData {
        let reader: NotesReader
        let notes: [NoteItem]
    }

    /// The device whose backup to read; nil means the newest backup of any device.
    private(set) var udid: String?
    @Published private(set) var sourceKind: SourceKind = .mac
    @Published private(set) var backups: [IOSBackupInfo] = []
    @Published private(set) var phase: Phase = .idle
    @Published var section: Section = .access
    @Published private(set) var conversations: [MessagingService: Loadable<ConversationData>] = [:]
    @Published var selectedThread: [MessagingService: String] = [:]
    /// A message to scroll to once its conversation is on screen (set by search).
    @Published var focusMessage: String?
    @Published var selectedNote: Int64?
    @Published private(set) var notes = Loadable<NotesData>()
    @Published private(set) var calls = Loadable<[CallRecord]>()
    @Published private(set) var bookmarks = Loadable<[SafariBookmark]>()
    @Published private(set) var history = Loadable<[SafariVisit]>()
    /// Bumped whenever data is re-read, so open conversations refresh.
    @Published private(set) var revision = 0
    @Published private(set) var indexedCount = 0
    @Published private(set) var isIndexing = false
    /// True while DiskScout is watching this Mac's databases for new data.
    @Published private(set) var isLive = false
    @Published private(set) var instagramExportPath: String? = UserDefaults.standard.string(forKey: "instagramExportPath")
    /// The Instagram section shows conversations, or every other page of the export.
    enum InstagramPane: String, CaseIterable, Identifiable {
        case messages = "Messages", everything = "Everything Else"
        var id: String { rawValue }
    }
    @Published var instagramPane: InstagramPane = .messages
    /// The export's other pages (contacts, followers, logins, ads…). Empty for a JSON export.
    @Published private(set) var exportPages: [ExportPageRef] = []
    @Published private(set) var selectedExportPage: String?
    @Published private(set) var exportPage = Loadable<ExportPage>()
    /// Which kinds of data exist on this Mac (for the access map); nil until checked.
    @Published private(set) var macHas: [PersonalDataItem: Bool]?
    /// Bundle id → app name, for calls placed through apps (WhatsApp, Telegram…).
    var appNames: [String: String] = [:]

    private(set) var source: PersonalDataSource?
    private var instagramStore: InstagramExportStore?
    private let index = try? SearchIndex()
    private var liveTask: Task<Void, Never>?
    private var tokens: [PersonalDataItem: String] = [:]
    private var indexJobs = 0

    init(udid: String? = nil) { self.udid = udid }

    /// Ties the backup source to a device (or to none). The Mac source doesn't depend on it.
    func setDevice(_ id: String?) {
        guard id != udid else { return }
        udid = id
        if sourceKind == .backup {
            closeSource()
            phase = .idle
            refresh()
        }
        refreshAvailability()
    }

    private func matching(_ list: [IOSBackupInfo]) -> [IOSBackupInfo] {
        guard let udid else { return list }
        return list.filter { $0.udid == udid || $0.id == udid }
    }

    /// Keychain account for the open backup's password.
    private var passwordAccount: String { current?.udid ?? udid ?? "any" }

    /// The newest backup of this device.
    var current: IOSBackupInfo? { backups.first }
    var isOpen: Bool { source != nil }

    func conversation(_ s: MessagingService) -> Loadable<ConversationData> { conversations[s] ?? Loadable() }

    /// Where a section's data comes from, in words (shown on every section).
    func provenance(for s: Section) -> (label: String, detail: String, level: AccessLevel) {
        if s == .instagram { return ("OFFICIAL EXPORT", "Read from the export Instagram gave you", .export) }
        switch sourceKind {
        case .mac: return (isLive ? "ON THIS MAC · LIVE" : "ON THIS MAC", "Read from this Mac's own copy, kept current by iCloud or the app", .onThisMac)
        case .backup: return ("IPHONE BACKUP" + (current?.date.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""), "Read from the backup; as old as the backup is", .backupOnly)
        }
    }

    // MARK: Choosing and opening a source

    /// Opens the current source the first time the tab is shown: this Mac straight away; a backup
    /// when it's unencrypted or its password was remembered.
    func start() async {
        refreshAvailability()
        guard source == nil, phase != .unlocking else { return }
        switch sourceKind {
        case .mac:
            openMac()
        case .backup:
            refresh()
            if case .ready(let b) = phase, b.isComplete {
                if !b.isEncrypted { await open(password: nil) } else { _ = await openWithRememberedPassword() }
            }
        }
    }

    func switchSource(to kind: SourceKind) async {
        guard kind != sourceKind else { return }
        closeSource()
        sourceKind = kind
        phase = .idle
        await start()
    }

    private var usingSampleData: Bool { ProcessInfo.processInfo.environment["DISKSCOUT_MAC_DATA_ROOT"] != nil }

    private func openMac() {
        // Without Full Disk Access every read would fail; say so up front (sample data skips this).
        if !usingSampleData, !DiskWalker.hasFullDiskAccess() {
            phase = .noAccess
            return
        }
        do {
            source = try MacSyncedData()
            phase = .open
            load(section)
            startLive()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Finds this device's backups (backup source only).
    func refresh() {
        guard sourceKind == .backup, source == nil, phase != .unlocking else { return }
        do {
            backups = matching(try BackupStore.list())
            if let b = current { phase = .ready(b) } else { phase = .none }
        } catch BackupStore.Failure.noAccess {
            phase = .noAccess
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Opens the backup. Returns an error message for the unlock sheet, or nil on success.
    @discardableResult
    func open(password: String?, remember: Bool = false) async -> String? {
        guard let info = current else { return "There's no backup of this device yet." }
        phase = .unlocking
        lastOpenError = nil
        do {
            let a = try await Task.detached(priority: .userInitiated) { try BackupArchive.open(info, password: password) }.value
            // Unlocking takes seconds. If the user moved to another source meanwhile, discard this one.
            guard sourceKind == .backup, source == nil, current == info else {
                a.close()
                return nil
            }
            source = a
            phase = .open
            if remember, let password { BackupPasswordStore.save(password, for: passwordAccount) }
            load(section)
            return nil
        } catch {
            lastOpenError = error
            if sourceKind == .backup, source == nil { phase = .ready(info) }
            return error.localizedDescription
        }
    }

    private var lastOpenError: Error?

    /// Unlocks with a password the user chose to remember, if there is one.
    func openWithRememberedPassword() async -> Bool {
        guard current?.isEncrypted == true, let saved = BackupPasswordStore.load(for: passwordAccount) else { return false }
        if await open(password: saved) == nil { return isOpen }
        // Forget it only when it's really the wrong password, not for a passing read error.
        if (lastOpenError as? BackupCryptoError) == .wrongPassword { BackupPasswordStore.delete(for: passwordAccount) }
        return false
    }

    private func closeSource() {
        liveTask?.cancel()
        liveTask = nil
        isLive = false
        tokens = [:]
        source?.close()
        source = nil
        for s in [MessagingService.whatsapp, .messages] {
            conversations[s] = nil
            selectedThread[s] = nil
            index?.remove(group: s.rawValue)
        }
        for g in ["notes", "calls", "safari"] { index?.remove(group: g) }
        notes = .init(); calls = .init(); bookmarks = .init(); history = .init()
        selectedNote = nil
        focusMessage = nil
        indexedCount = index?.count ?? 0
    }

    /// Closes the source and deletes every private copy (locks an encrypted backup again).
    func close() {
        closeSource()
        instagramStore?.close()
        instagramStore = nil
        conversations[.instagram] = nil
        index?.remove(group: MessagingService.instagram.rawValue)
        phase = .idle
        refresh()
    }

    /// Re-reads everything from the current source.
    func reload() async {
        closeSource()
        phase = .idle
        await start()
    }

    func forgetPassword() { BackupPasswordStore.delete(for: passwordAccount) }
    var hasRememberedPassword: Bool { BackupPasswordStore.load(for: passwordAccount) != nil }

    /// What a section from this Mac does and doesn't include.
    func sourceNote(for s: Section) -> String? {
        if s == .instagram { return "From Instagram's own export. Messages sent after you requested it aren't included." }
        guard sourceKind == .mac else { return nil }
        switch s {
        case .whatsapp: return "From WhatsApp for Mac: the history it synced when you linked it to your phone."
        case .messages: return "iMessage and SMS on this Mac. Turn on Messages in iCloud (or Text Message Forwarding) on the iPhone to keep it complete."
        case .notes: return "iCloud notes and notes on this Mac. Notes kept only “On My iPhone” aren't here."
        case .calls: return "Calls synced to this Mac through iCloud, including your iPhone's."
        case .safari: return "Bookmarks synced through iCloud, and history from this Mac and your other devices."
        case .access, .instagram: return nil
        }
    }

    // MARK: Access map facts

    /// Checks what exists on this Mac and whether a backup exists. Reads no content.
    func refreshAvailability() {
        let home = MacSyncedData.home
        let fm = FileManager.default
        func has(_ p: String) -> Bool { fm.fileExists(atPath: home.appendingPathComponent(p).path) }
        macHas = [
            .whatsapp: MacSyncedData.whatsappContainers.contains { has($0.0 + "/" + WhatsAppReader.databasePath) },
            .messages: has(MessagesStore.macDatabasePath),
            .notes: has(MacSyncedData.notesPath),
            .calls: has(MacSyncedData.callsPath),
            .safari: has(MacSyncedData.bookmarksPath) || has(MacSyncedData.historyPath),
        ]
        if sourceKind == .mac, let list = try? BackupStore.list() {
            backups = matching(list)
        }
    }

    // MARK: Loading sections

    private func missingText(_ s: Section) -> String {
        switch (s, sourceKind) {
        case (.whatsapp, .mac): return "WhatsApp for Mac isn't set up on this Mac. Link it to your phone to read chats here."
        case (.whatsapp, .backup): return "WhatsApp isn't in this backup."
        case (.messages, .mac): return "Messages isn't set up on this Mac. Sign in to Messages with your Apple ID and turn on Messages in iCloud."
        case (.messages, .backup): return "This backup has no messages. With Messages in iCloud on, messages aren't put in backups."
        case (.notes, .mac): return "Notes isn't set up on this Mac."
        case (.notes, .backup): return "Notes isn't in this backup. Notes kept only in iCloud aren't stored on the iPhone."
        case (.calls, .mac): return "This Mac has no call history. iPhone calls appear here when the Mac uses the same Apple ID and “Calls on Other Devices” is on."
        case (.calls, .backup): return "This backup has no call history."
        default: return "Nothing here."
        }
    }

    private func finish<T>(_ result: Result<T?, Error>, missing: String, store: (Loadable<T>) -> Void, current: Loadable<T>) {
        var l = current
        l.loading = false
        switch result {
        case .success(let v?): l.value = v; l.error = nil; l.missing = nil
        case .success(nil): if l.value == nil { l.missing = missing }
        case .failure(MacSyncedData.Failure.noAccess): phase = .noAccess
        case .failure(let e): if l.value == nil { l.error = e.localizedDescription }
        }
        store(l)
    }

    /// Loads a section if it hasn't been yet. `force` re-reads quietly, keeping what's on screen
    /// until the new data is ready (used by live refresh).
    func load(_ s: Section, force: Bool = false) {
        if let service = s.service { loadConversations(service, force: force); return }
        guard let source else { return }
        switch s {
        case .access, .whatsapp, .messages, .instagram:
            break
        case .notes:
            guard force || (notes.value == nil && !notes.loading && notes.missing == nil) else { return }
            if !force { notes.loading = true }
            let missing = missingText(.notes)
            Task {
                let result: Result<NotesData?, Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        guard let url = try source.notesDatabase() else { return nil }
                        let reader = try NotesReader(databaseAt: url)
                        return NotesData(reader: reader, notes: try reader.notes())
                    }
                }.value
                guard self.source === source else { return }
                finish(result, missing: missing, store: { self.notes = $0 }, current: notes)
                if let data = try? result.get() { indexNotes(data) }
                revision += 1
            }
        case .calls:
            guard force || (calls.value == nil && !calls.loading && calls.missing == nil) else { return }
            if !source.includesCallAndBrowsingHistory {
                calls.missing = "Apple only puts call history in encrypted backups. Tick “Encrypt local backup” in Finder and back up again."
                return
            }
            if !force { calls.loading = true }
            let names = appNames, missing = missingText(.calls)
            Task {
                let result: Result<[CallRecord]?, Error> = await Task.detached(priority: .userInitiated) {
                    Result {
                        guard let url = try source.callHistoryDatabase() else { return nil }
                        return try CallHistoryReader.calls(databaseAt: url, contacts: source.contactNames(), appNames: names)
                    }
                }.value
                guard self.source === source else { return }
                finish(result, missing: missing, store: { self.calls = $0 }, current: calls)
                if let list = try? result.get() { indexCalls(list) }
            }
        case .safari:
            if force || (bookmarks.value == nil && !bookmarks.loading && bookmarks.missing == nil) {
                if !force { bookmarks.loading = true }
                Task {
                    let result: Result<[SafariBookmark]?, Error> = await Task.detached(priority: .userInitiated) {
                        Result { try source.safariBookmarks() }
                    }.value
                    guard self.source === source else { return }
                    finish(result, missing: "No Safari bookmarks here.", store: { self.bookmarks = $0 }, current: bookmarks)
                    indexSafari()
                }
            }
            if force || (history.value == nil && !history.loading && history.missing == nil) {
                if !source.includesCallAndBrowsingHistory {
                    history.missing = "Apple only puts Safari history in encrypted backups."
                    return
                }
                if !force { history.loading = true }
                Task {
                    let result: Result<[SafariVisit]?, Error> = await Task.detached(priority: .userInitiated) {
                        Result { try source.safariHistory() }
                    }.value
                    guard self.source === source else { return }
                    finish(result, missing: "No Safari history here.", store: { self.history = $0 }, current: history)
                    indexSafari()
                }
            }
        }
    }

    private func loadConversations(_ service: MessagingService, force: Bool) {
        let state = conversation(service)
        guard force || (state.value == nil && !state.loading && state.missing == nil) else { return }
        // An export that couldn't be read stays failed until another one is chosen. The setup
        // screen asks for a load every time it appears, so retrying here would loop forever.
        if service == .instagram, state.error != nil, !force { return }
        let make: @Sendable () throws -> ConversationStore?
        let missing: String
        switch service {
        case .instagram:
            if let store = instagramStore {
                make = { store }
            } else if let path = instagramExportPath, FileManager.default.fileExists(atPath: path) {
                make = { try InstagramExportStore(exportAt: URL(fileURLWithPath: path)) }
            } else {
                conversations[.instagram] = Loadable(missing: "none")
                return
            }
            missing = "none"
        case .whatsapp:
            guard let source else { return }
            missing = missingText(.whatsapp)
            make = {
                guard let db = try source.whatsappDatabase() else { return nil }
                let scope = db.mediaScope
                return WhatsAppStore(reader: try WhatsAppReader(databaseAt: db.url)) { try source.mediaFile(scope: scope, path: $0) }
            }
        case .messages:
            guard let source else { return }
            missing = missingText(.messages)
            make = {
                guard let url = try source.messagesDatabase() else { return nil }
                return try MessagesStore(databaseAt: url, contacts: source.contactNames()) { try source.messagesAttachment(storedPath: $0) }
            }
        }
        if !force { conversations[service] = Loadable(loading: true) }
        let expected = source
        Task {
            let result: Result<ConversationData?, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    guard let store = try make() else { return nil }
                    return ConversationData(store: store, threads: try store.threads())
                }
            }.value
            guard service == .instagram || self.source === expected else { return }
            finish(result, missing: missing, store: { self.conversations[service] = $0 }, current: conversation(service))
            if let data = try? result.get() {
                if service == .instagram {
                    instagramStore = data.store as? InstagramExportStore
                    exportPages = instagramStore?.pages ?? []
                }
                indexConversations(data, service: service)
            }
            revision += 1
        }
    }

    // MARK: Instagram export

    /// Opens an export folder or .zip the user chose, and remembers where it is.
    func openInstagramExport(_ url: URL) {
        instagramStore?.close()
        instagramStore = nil
        instagramExportPath = url.path
        UserDefaults.standard.set(url.path, forKey: "instagramExportPath")
        conversations[.instagram] = nil
        selectedThread[.instagram] = nil
        clearExportPages()
        loadConversations(.instagram, force: false)
    }

    private func clearExportPages() {
        exportPages = []
        selectedExportPage = nil
        exportPage = Loadable()
    }

    /// Reads one of the export's other pages. Pages are read when opened, not all up front:
    /// "Stories viewed" alone can be tens of megabytes.
    func openExportPage(_ id: String?) {
        guard id != selectedExportPage || exportPage.error != nil else { return }
        selectedExportPage = id
        guard let id, let store = instagramStore, let ref = exportPages.first(where: { $0.id == id }) else {
            exportPage = Loadable()
            return
        }
        exportPage = Loadable(loading: true)
        Task {
            let result = await Task.detached(priority: .userInitiated) { Result { try store.page(ref) } }.value
            guard selectedExportPage == id else { return }
            switch result {
            case .success(let page): exportPage = Loadable(value: page)
            case .failure(let error): exportPage = Loadable(error: error.localizedDescription)
            }
        }
    }

    /// The page as Instagram wrote it, to open in a browser.
    func exportPageFile(_ id: String) -> URL? {
        exportPages.first { $0.id == id }.flatMap { instagramStore?.pageFile($0) }
    }

    /// A photo or video a page refers to. Unpacks it from the .zip first if it's still packed.
    func exportMedia(_ path: String) async -> URL? {
        guard let store = instagramStore else { return nil }
        return await Task.detached { store.mediaFile(path) }.value
    }

    func forgetInstagramExport() {
        instagramStore?.close()
        instagramStore = nil
        instagramExportPath = nil
        UserDefaults.standard.removeObject(forKey: "instagramExportPath")
        conversations[.instagram] = nil
        selectedThread[.instagram] = nil
        clearExportPages()
        index?.remove(group: MessagingService.instagram.rawValue)
        indexedCount = index?.count ?? 0
    }

    // MARK: Search index (in memory only)

    private func runIndexJob(_ work: @escaping @Sendable (SearchIndex) -> Void) {
        guard let index else { return }
        indexJobs += 1
        isIndexing = true
        Task {
            await Task.detached(priority: .utility) { work(index) }.value
            indexJobs -= 1
            isIndexing = indexJobs > 0
            indexedCount = index.count
        }
    }

    private func indexConversations(_ data: ConversationData, service: MessagingService) {
        let titles = Dictionary(data.threads.map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let store = data.store
        runIndexJob { index in
            index.replace(group: service.rawValue) { add in
                try? store.forEachText { thread, id, date, sender, text in
                    let chat = titles[thread] ?? ""
                    add(.init(kind: .message, service: service, ref: id, thread: thread,
                              title: [sender, chat].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), body: text, date: date))
                }
            }
        }
    }

    private func indexNotes(_ data: NotesData) {
        let reader = data.reader, notes = data.notes
        runIndexJob { index in
            index.replace(group: "notes") { add in
                for n in notes where !n.isLocked {
                    add(.init(kind: .note, ref: String(n.id), title: n.title, body: reader.body(of: n.id) ?? n.snippet ?? "", date: n.modified))
                }
            }
        }
    }

    private func indexCalls(_ list: [CallRecord]) {
        runIndexJob { index in
            index.replace(group: "calls") { add in
                for c in list {
                    add(.init(kind: .call, ref: String(c.id), title: c.name ?? c.number ?? "Unknown",
                              body: [c.direction, c.service, c.number, c.location].compactMap { $0 }.joined(separator: " "), date: c.date))
                }
            }
        }
    }

    private func indexSafari() {
        let visits = history.value ?? []
        var flat: [SafariBookmark] = []
        func walk(_ items: [SafariBookmark]) { for b in items { if b.isFolder { walk(b.children ?? []) } else { flat.append(b) } } }
        walk(bookmarks.value ?? [])
        let marks = flat
        runIndexJob { index in
            index.replace(group: "safari") { add in
                for b in marks { add(.init(kind: .bookmark, ref: String(b.id), title: b.title, body: b.url ?? "")) }
                for v in visits { add(.init(kind: .visit, ref: String(v.id), title: v.title ?? v.host, body: v.url, date: v.date)) }
            }
        }
    }

    /// Searches everything loaded so far. Loads the remaining sections first so results are complete.
    func search(_ text: String) async -> [SearchIndex.Hit] {
        guard let index else { return [] }
        for s in Section.allCases where s != .access { load(s) }
        return await Task.detached(priority: .userInitiated) { index.search(text) }.value
    }

    /// Jumps to a search result.
    func open(_ hit: SearchIndex.Hit) {
        switch hit.kind {
        case .message:
            guard let service = hit.service else { return }
            selectedThread[service] = hit.thread
            focusMessage = hit.ref
            section = Section(service)
        case .note:
            selectedNote = Int64(hit.ref)
            section = .notes
        case .call:
            section = .calls
        case .visit, .bookmark:
            section = .safari
        }
    }

    // MARK: Live refresh (This Mac)

    /// Watches this Mac's databases and re-reads a section a few seconds after it changes.
    private func startLive() {
        liveTask?.cancel()
        guard let source, sourceKind == .mac else { return }
        isLive = true
        for item in PersonalDataItem.allCases { tokens[item] = source.changeToken(for: item) }
        liveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let self, !Task.isCancelled, self.source === source else { return }
                for item in PersonalDataItem.allCases {
                    let token = source.changeToken(for: item)
                    guard token != self.tokens[item] else { continue }
                    self.tokens[item] = token
                    switch item {
                    case .whatsapp: if self.conversation(.whatsapp).value != nil { self.load(.whatsapp, force: true) }
                    case .messages: if self.conversation(.messages).value != nil { self.load(.messages, force: true) }
                    case .notes: if self.notes.value != nil { self.load(.notes, force: true) }
                    case .calls: if self.calls.value != nil { self.load(.calls, force: true) }
                    case .safari: if self.bookmarks.value != nil || self.history.value != nil { self.load(.safari, force: true) }
                    }
                }
            }
        }
    }

    /// Deletes decrypted copies left behind by a previous run that didn't quit normally.
    nonisolated static func removeStaleCopies() {
        let tmp = FileManager.default.temporaryDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        where name.hasPrefix("DiskScout-backup-") || name.hasPrefix("DiskScout-photosdb-") || name == "DiskScout-video" {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }
}

/// How a kind of data can be reached. Shown everywhere data appears, so it's always clear
/// whether something is live, a synced copy, an export, from a backup, or off limits.
enum AccessLevel: String, CaseIterable {
    case direct = "Direct from iPhone"
    case onThisMac = "On this Mac"
    case export = "Official export"
    case backupOnly = "Backup only"
    case restricted = "Restricted"

    var color: Color {
        switch self {
        case .direct: return SafetyLevel.safe.color
        case .onThisMac: return Color(red: 0.30, green: 0.60, blue: 1.0)
        case .export: return Color(red: 0.74, green: 0.47, blue: 1.0)
        case .backupOnly: return SafetyLevel.caution.color
        case .restricted: return SafetyLevel.protected.color
        }
    }

    var systemImage: String {
        switch self {
        case .direct: return "cable.connector"
        case .onThisMac: return "laptopcomputer"
        case .export: return "square.and.arrow.down.on.square"
        case .backupOnly: return "externaldrive.fill"
        case .restricted: return "lock.fill"
        }
    }

    var meaning: String {
        switch self {
        case .direct: return "Read live from the iPhone over the cable."
        case .onThisMac: return "Read from this Mac's own copy, synced by iCloud or the app. No backup."
        case .export: return "Read from an export the service itself gives you."
        case .backupOnly: return "Only inside an iPhone backup. Used only when you choose it."
        case .restricted: return "iOS doesn't let any Mac app read this."
        }
    }
}
