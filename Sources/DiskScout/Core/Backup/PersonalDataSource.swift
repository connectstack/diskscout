import Foundation

/// Somewhere DiskScout can read personal data from: an iPhone backup, or the copies that
/// iCloud and WhatsApp for Mac keep on this Mac. Both use the same database formats.
protocol PersonalDataSource: AnyObject, Sendable {
    /// The first WhatsApp (or WhatsApp Business) chat database: a private copy, its app name,
    /// and a scope token for resolving media paths.
    func whatsappDatabase() throws -> (url: URL, appName: String, mediaScope: String)?
    /// A readable copy of a WhatsApp attachment ("Message/Media/…"), or nil if it isn't there.
    func mediaFile(scope: String, path: String) throws -> URL?
    /// The Messages (iMessage/SMS) database.
    func messagesDatabase() throws -> URL?
    /// A readable copy of a Messages attachment, given the path stored in the database ("~/Library/…").
    func messagesAttachment(storedPath: String) throws -> URL?
    func notesDatabase() throws -> URL?
    func callHistoryDatabase() throws -> URL?
    /// Changes whenever the underlying data does (nil when the source can't change, like a backup).
    func changeToken(for item: PersonalDataItem) -> String?
    /// Phone number (last 10 digits) → contact name.
    func contactNames() -> [String: String]
    func safariBookmarks() throws -> [SafariBookmark]?
    func safariHistory() throws -> [SafariVisit]?
    /// False for unencrypted backups, which Apple strips of call and browsing history.
    var includesCallAndBrowsingHistory: Bool { get }
    /// Deletes every private copy made from this source.
    func close()
}

enum PersonalDataItem: String, CaseIterable, Sendable {
    case whatsapp, messages, notes, calls, safari
}

// MARK: - iPhone backup

extension BackupArchive: PersonalDataSource {
    func whatsappDatabase() throws -> (url: URL, appName: String, mediaScope: String)? {
        for source in WhatsAppReader.sources {
            if let url = try extractDatabase(domain: source.domain, path: WhatsAppReader.databasePath) {
                return (url, source.name, source.domain)
            }
        }
        return nil
    }

    func mediaFile(scope: String, path: String) throws -> URL? {
        guard let e = entry(domain: scope, path: path) else { return nil }
        return try extractToWork(e)
    }

    func messagesDatabase() throws -> URL? {
        try extractDatabase(domain: MessagesStore.backupSource.domain, path: MessagesStore.backupSource.path)
    }

    func messagesAttachment(storedPath: String) throws -> URL? {
        // "~/Library/SMS/Attachments/…" lives in MediaDomain as "Library/SMS/Attachments/…".
        guard let r = storedPath.range(of: "Library/SMS/") else { return nil }
        guard let e = entry(domain: MessagesStore.backupAttachmentDomain, path: String(storedPath[r.lowerBound...])) else { return nil }
        return try extractToWork(e)
    }

    func changeToken(for item: PersonalDataItem) -> String? { nil }

    func notesDatabase() throws -> URL? {
        try extractDatabase(domain: NotesReader.domain, path: NotesReader.databasePath)
    }

    func callHistoryDatabase() throws -> URL? {
        try extractDatabase(domain: CallHistoryReader.domain, path: CallHistoryReader.databasePath)
    }

    func contactNames() -> [String: String] {
        ((try? extractDatabase(domain: ContactsReader.domain, path: ContactsReader.databasePath)) ?? nil)
            .map(ContactsReader.phoneNames(databaseAt:)) ?? [:]
    }

    func safariBookmarks() throws -> [SafariBookmark]? {
        guard let url = try extractDatabase(domain: SafariReader.bookmarksSource.domain, path: SafariReader.bookmarksSource.path) else { return nil }
        return try SafariReader.bookmarks(databaseAt: url)
    }

    func safariHistory() throws -> [SafariVisit]? {
        for source in SafariReader.historySources {
            if let url = try extractDatabase(domain: source.domain, path: source.path) { return try SafariReader.history(databaseAt: url) }
        }
        return nil
    }

    var includesCallAndBrowsingHistory: Bool { info.isEncrypted }
}

// MARK: - This Mac

/// The copies already on this Mac: WhatsApp for Mac's chats, Notes (iCloud), call history
/// (iPhone calls arrive through iCloud) and Safari (iCloud bookmarks and other devices' history).
/// Databases are copied, with their write-ahead logs, into a private folder before reading, so the
/// live files the apps are using are never opened.
final class MacSyncedData: PersonalDataSource, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noAccess
        var errorDescription: String? { "macOS keeps this data private. Give DiskScout Full Disk Access to read it." }
    }

    /// The home folder to read from; `DISKSCOUT_MAC_DATA_ROOT` overrides it (tests and sample data).
    static var home: URL {
        if let custom = ProcessInfo.processInfo.environment["DISKSCOUT_MAC_DATA_ROOT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static let whatsappContainers = [
        ("Library/Group Containers/group.net.whatsapp.WhatsApp.shared", "WhatsApp"),
        ("Library/Group Containers/group.net.whatsapp.WhatsAppSMB.shared", "WhatsApp Business"),
    ]
    static let notesPath = "Library/Group Containers/group.com.apple.notes/NoteStore.sqlite"
    static let callsPath = "Library/Application Support/CallHistoryDB/CallHistory.storedata"
    static let contactsDir = "Library/Application Support/AddressBook"
    static let bookmarksPath = "Library/Safari/Bookmarks.plist"
    static let historyPath = "Library/Safari/History.db"

    let home: URL
    let workDir: URL
    private let lock = NSLock()
    private var closed = false
    /// Source path → its last two private copies. A reader may still have the previous one open
    /// while live refresh makes a new one, so only the copy before that is deleted.
    private var generations: [String: [URL]] = [:]

    init(home: URL = MacSyncedData.home) throws {
        self.home = home
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScout-backup-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    deinit { close() }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: workDir)
    }

    /// Copies a database and its -wal/-shm into the private folder. nil when it doesn't exist.
    func copyDatabase(_ relativePath: String) throws -> URL? {
        try copyDatabase(at: home.appendingPathComponent(relativePath))
    }

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func copyDatabase(at source: URL) throws -> URL? {
        guard !isClosed else { throw CancellationError() }
        // A load still running when the source closes must not leave private copies behind.
        defer { if isClosed { try? FileManager.default.removeItem(at: workDir) } }
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            // A missing file and a hidden one look the same; tell them apart by trying the folder.
            if (try? fm.contentsOfDirectory(atPath: source.deletingLastPathComponent().path)) == nil,
               fm.fileExists(atPath: source.deletingLastPathComponent().path) { throw Failure.noAccess }
            return nil
        }
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dest = dir.appendingPathComponent(source.lastPathComponent)
        do {
            try fm.copyItem(at: source, to: dest)
        } catch let e as NSError where e.code == NSFileReadNoPermissionError || e.code == 257 || (e.domain == NSPOSIXErrorDomain && e.code == Int(EPERM)) {
            throw Failure.noAccess
        }
        for suffix in ["-wal", "-shm"] {
            let side = URL(fileURLWithPath: source.path + suffix)
            if fm.fileExists(atPath: side.path) { try? fm.copyItem(at: side, to: URL(fileURLWithPath: dest.path + suffix)) }
        }
        lock.lock()
        var kept = generations[source.path] ?? []
        kept.append(dir)
        let stale = kept.count > 2 ? Array(kept.prefix(kept.count - 2)) : []
        generations[source.path] = Array(kept.suffix(2))
        lock.unlock()
        for old in stale { try? fm.removeItem(at: old) }
        return dest
    }

    func whatsappDatabase() throws -> (url: URL, appName: String, mediaScope: String)? {
        for (container, name) in Self.whatsappContainers {
            if let url = try copyDatabase(container + "/" + WhatsAppReader.databasePath) { return (url, name, container) }
        }
        return nil
    }

    func mediaFile(scope: String, path: String) throws -> URL? {
        // Read-only previews can use the file where it is, but only inside that app's own folder.
        let container = home.appendingPathComponent(scope).standardizedFileURL
        let url = container.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(container.path + "/") else { return nil }
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    func messagesDatabase() throws -> URL? { try copyDatabase(MessagesStore.macDatabasePath) }

    func messagesAttachment(storedPath: String) throws -> URL? {
        // Stored as "~/Library/Messages/Attachments/…". Only that folder is ever served.
        guard let r = storedPath.range(of: "Library/Messages/Attachments/") else { return nil }
        let relative = String(storedPath[r.lowerBound...])
        guard !relative.contains("/../") else { return nil }
        let url = home.appendingPathComponent(relative)
        return FileManager.default.isReadableFile(atPath: url.path) ? url : nil
    }

    /// Size and modification time of a database and its write-ahead log: changes when new data arrives.
    func changeToken(for item: PersonalDataItem) -> String? {
        let paths: [String]
        switch item {
        case .whatsapp: paths = Self.whatsappContainers.map { $0.0 + "/" + WhatsAppReader.databasePath }
        case .messages: paths = [MessagesStore.macDatabasePath]
        case .notes: paths = [Self.notesPath]
        case .calls: paths = [Self.callsPath]
        case .safari: paths = [Self.historyPath, Self.bookmarksPath]
        }
        var parts: [String] = []
        for p in paths {
            for suffix in ["", "-wal"] {
                var st = stat()
                if stat(home.appendingPathComponent(p).path + suffix, &st) == 0 {
                    parts.append("\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)")
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "|")
    }

    func notesDatabase() throws -> URL? { try copyDatabase(Self.notesPath) }
    func callHistoryDatabase() throws -> URL? { try copyDatabase(Self.callsPath) }

    func contactNames() -> [String: String] {
        let dir = home.appendingPathComponent(Self.contactsDir)
        var dbs = [dir.appendingPathComponent("AddressBook-v22.abcddb")]
        let sources = dir.appendingPathComponent("Sources")
        for s in (try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? [] {
            dbs.append(sources.appendingPathComponent(s).appendingPathComponent("AddressBook-v22.abcddb"))
        }
        var out: [String: String] = [:]
        for db in dbs {
            guard let copy = try? copyDatabase(at: db) else { continue }
            out.merge(ContactsReader.macPhoneNames(databaseAt: copy)) { a, _ in a }
        }
        return out
    }

    func safariBookmarks() throws -> [SafariBookmark]? {
        let url = home.appendingPathComponent(Self.bookmarksPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw Failure.noAccess }
        return SafariReader.macBookmarks(plistData: data)
    }

    func safariHistory() throws -> [SafariVisit]? {
        guard let url = try copyDatabase(Self.historyPath) else { return nil }
        return try SafariReader.history(databaseAt: url)
    }

    var includesCallAndBrowsingHistory: Bool { true }
}

extension ContactsReader {
    /// macOS Contacts (Core Data): ZABCDRECORD people, ZABCDPHONENUMBER numbers.
    static func macPhoneNames(databaseAt url: URL) -> [String: String] {
        guard let db = try? SQLiteDB(path: url.path), db.tables().isSuperset(of: ["ZABCDRECORD", "ZABCDPHONENUMBER"]) else { return [:] }
        var out: [String: String] = [:]
        try? db.query("""
            SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION, p.ZFULLNUMBER FROM ZABCDPHONENUMBER p
            JOIN ZABCDRECORD r ON r.Z_PK = p.ZOWNER WHERE p.ZFULLNUMBER IS NOT NULL
            """) { r in
            guard let number = r.string(3) else { return }
            let name = [r.string(0), r.string(1)].compactMap { $0 }.joined(separator: " ")
            let display = name.isEmpty ? (r.string(2) ?? "") : name
            let k = key(number)
            if !display.isEmpty, k.count >= 6 { out[k] = display }
        }
        if db.tables().contains("ZABCDEMAILADDRESS") {
            try? db.query("""
                SELECT r.ZFIRSTNAME, r.ZLASTNAME, r.ZORGANIZATION, e.ZADDRESS FROM ZABCDEMAILADDRESS e
                JOIN ZABCDRECORD r ON r.Z_PK = e.ZOWNER WHERE e.ZADDRESS IS NOT NULL
                """) { r in
                guard let address = r.string(3) else { return }
                let name = [r.string(0), r.string(1)].compactMap { $0 }.joined(separator: " ")
                let display = name.isEmpty ? (r.string(2) ?? "") : name
                if !display.isEmpty { out[address.lowercased()] = display }
            }
        }
        return out
    }
}

extension SafariReader {
    /// Safari for Mac keeps bookmarks in a property list (synced with the iPhone through iCloud).
    static func macBookmarks(plistData: Data) -> [SafariBookmark] {
        guard let root = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] else { return [] }
        var nextID = 1
        func build(_ node: [String: Any], depth: Int) -> SafariBookmark? {
            let type = node["WebBookmarkType"] as? String
            nextID += 1
            switch type {
            case "WebBookmarkTypeList":
                let kids = depth < 32 ? ((node["Children"] as? [[String: Any]]) ?? []).compactMap { build($0, depth: depth + 1) } : []
                return SafariBookmark(id: nextID, title: folderTitle(node["Title"] as? String) ?? "Folder", url: nil, isFolder: true, children: kids)
            case "WebBookmarkTypeLeaf":
                let url = node["URLString"] as? String
                let title = ((node["URIDictionary"] as? [String: Any])?["title"] as? String) ?? (node["Title"] as? String) ?? url ?? "Untitled"
                return SafariBookmark(id: nextID, title: title, url: url, isFolder: false, children: nil)
            default:
                return nil   // History / Bookmarks proxies
            }
        }
        let top = ((root["Children"] as? [[String: Any]]) ?? []).compactMap { build($0, depth: 0) }
        return top.filter { !$0.isFolder || !($0.children ?? []).isEmpty }
    }
}
