import Foundation
import Security

/// The per-file record stored (NSKeyedArchiver) in Manifest.db's `file` column. Only the fields
/// DiskScout needs are decoded, with secure coding so nothing else is ever instantiated.
@objc(DSBackupFileRecord)
final class BackupFileRecord: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }

    var size: Int64
    var protectionClass: Int
    var encryptionKey: Data?
    var lastModified: Int64

    init(size: Int64, protectionClass: Int, encryptionKey: Data?, lastModified: Int64) {
        self.size = size
        self.protectionClass = protectionClass
        self.encryptionKey = encryptionKey
        self.lastModified = lastModified
    }

    required init?(coder: NSCoder) {
        size = coder.decodeInt64(forKey: "Size")
        protectionClass = Int(coder.decodeInt64(forKey: "ProtectionClass"))
        encryptionKey = coder.decodeObject(of: NSData.self, forKey: "EncryptionKey") as Data?
        lastModified = coder.decodeInt64(forKey: "LastModified")
    }

    func encode(with coder: NSCoder) {
        coder.encode(size, forKey: "Size")
        coder.encode(Int64(protectionClass), forKey: "ProtectionClass")
        if let encryptionKey { coder.encode(encryptionKey as NSData, forKey: "EncryptionKey") }
        coder.encode(lastModified, forKey: "LastModified")
    }

    static func decode(_ blob: Data) -> BackupFileRecord? {
        guard let u = try? NSKeyedUnarchiver(forReadingFrom: blob) else { return nil }
        u.requiresSecureCoding = true
        u.setClass(BackupFileRecord.self, forClassName: "MBFile")
        defer { u.finishDecoding() }
        return u.decodeObject(of: BackupFileRecord.self, forKey: NSKeyedArchiveRootObjectKey)
    }

    func archived() throws -> Data {
        let a = NSKeyedArchiver(requiringSecureCoding: true)
        a.setClassName("MBFile", for: BackupFileRecord.self)
        a.encode(self, forKey: NSKeyedArchiveRootObjectKey)
        a.finishEncoding()
        return a.encodedData
    }
}

/// An opened backup: its file list, and decrypted copies of the files DiskScout reads.
/// Decrypted data only ever lives in a private temporary folder that `close()` deletes.
final class BackupArchive: @unchecked Sendable {
    struct Entry: Hashable {
        let fileID: String
        let domain: String
        let relativePath: String
        let flags: Int          // 1 file, 2 folder, 4 symbolic link
        var isFile: Bool { flags == 1 }
    }

    enum Failure: LocalizedError, Equatable {
        case passwordRequired, incomplete, missingManifest, missingFile(String), badRecord
        var errorDescription: String? {
            switch self {
            case .passwordRequired: return "This backup is encrypted. Enter the password you chose in Finder."
            case .incomplete: return "This backup didn't finish. Back up the iPhone again, then try once more."
            case .missingManifest: return "This backup is missing its file list (Manifest.db)."
            case .missingFile(let p): return "The backup doesn't contain \(p)."
            case .badRecord: return "A file record in the backup couldn't be read."
            }
        }
    }

    let info: IOSBackupInfo
    let workDir: URL
    private let keybag: BackupKeybag?
    private let manifest: SQLiteDB
    private let lock = NSLock()
    private var closed = false

    /// Opens a backup. Encrypted backups need the password; unlocking takes a few seconds by
    /// design (Apple's key derivation), so call this off the main thread.
    static func open(_ info: IOSBackupInfo, password: String?) throws -> BackupArchive {
        let manifestURL = info.url.appendingPathComponent("Manifest.db")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { throw info.isComplete ? Failure.missingManifest : Failure.incomplete }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScout-backup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            if info.isEncrypted {
                guard let password, !password.isEmpty else { throw Failure.passwordRequired }
                let plistData = try Data(contentsOf: info.url.appendingPathComponent("Manifest.plist"))
                let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] ?? [:]
                guard let bagData = plist["BackupKeyBag"] as? Data, let manifestKey = plist["ManifestKey"] as? Data else {
                    throw BackupCryptoError.badKeybag("no keybag in Manifest.plist")
                }
                var bag = try BackupKeybag(bagData)
                try bag.unlock(password: password)
                let key = try bag.unwrapClassPrefixed(manifestKey)
                let size = ((try? FileManager.default.attributesOfItem(atPath: manifestURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
                let plain = work.appendingPathComponent("Manifest.db")
                try BackupAES.decryptFile(at: manifestURL, to: plain, key: key, size: size)
                let db = try SQLiteDB(path: plain.path)
                guard db.tables().contains("Files") else { throw BackupCryptoError.wrongPassword }
                return BackupArchive(info: info, workDir: work, keybag: bag, manifest: db)
            } else {
                let db = try SQLiteDB(path: manifestURL.path, readOnly: true)
                return BackupArchive(info: info, workDir: work, keybag: nil, manifest: db)
            }
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    private init(info: IOSBackupInfo, workDir: URL, keybag: BackupKeybag?, manifest: SQLiteDB) {
        self.info = info
        self.workDir = workDir
        self.keybag = keybag
        self.manifest = manifest
    }

    deinit { close() }

    /// Deletes every decrypted copy made from this backup.
    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        try? FileManager.default.removeItem(at: workDir)
    }

    // MARK: Lookups

    func entry(domain: String, path: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        var out: Entry?
        try? manifest.query("SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = ? AND relativePath = ? LIMIT 1", [domain, path]) { r in
            out = Entry(fileID: r.string(0) ?? "", domain: r.string(1) ?? "", relativePath: r.string(2) ?? "", flags: r.int(3))
        }
        return out
    }

    /// Files in a domain whose path starts with `prefix` ("" for the whole domain).
    func entries(domain: String, under prefix: String = "") -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        var out: [Entry] = []
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
        try? manifest.query("SELECT fileID, domain, relativePath, flags FROM Files WHERE domain = ? AND relativePath LIKE ? ESCAPE '\\'", [domain, escaped + "%"]) { r in
            out.append(Entry(fileID: r.string(0) ?? "", domain: r.string(1) ?? "", relativePath: r.string(2) ?? "", flags: r.int(3)))
        }
        return out
    }

    func domains() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var out: [String] = []
        try? manifest.query("SELECT DISTINCT domain FROM Files ORDER BY domain") { if let d = $0.string(0) { out.append(d) } }
        return out
    }

    func record(_ e: Entry) -> BackupFileRecord? {
        lock.lock(); defer { lock.unlock() }
        var blob: Data?
        try? manifest.query("SELECT file FROM Files WHERE fileID = ?", [e.fileID]) { blob = $0.data(0) }
        return blob.flatMap(BackupFileRecord.decode)
    }

    /// Where a file's (possibly encrypted) contents sit inside the backup folder.
    func payloadURL(_ e: Entry) -> URL? {
        // fileIDs are 40 lowercase hex characters; anything else could escape the backup folder.
        guard e.fileID.count == 40, e.fileID.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return info.url.appendingPathComponent(String(e.fileID.prefix(2)), isDirectory: true).appendingPathComponent(e.fileID)
    }

    // MARK: Extraction

    private var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    /// Writes a plain (decrypted) copy of a backed-up file to `destination`.
    func extract(_ e: Entry, to destination: URL) throws {
        guard !isClosed else { throw CancellationError() }
        // A load still running when the backup is locked must not leave decrypted data behind.
        defer { if isClosed { try? FileManager.default.removeItem(at: workDir) } }
        guard e.isFile, let source = payloadURL(e), FileManager.default.fileExists(atPath: source.path) else {
            throw Failure.missingFile(e.relativePath)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        guard let keybag else {
            try FileManager.default.copyItem(at: source, to: destination)
            return
        }
        guard let rec = record(e) else { throw Failure.badRecord }
        guard let wrapped = rec.encryptionKey, wrapped.count > 4 else {
            // Empty files are stored without a key.
            guard rec.size == 0 else { throw BackupCryptoError.noKeyForClass(rec.protectionClass) }
            FileManager.default.createFile(atPath: destination.path, contents: Data(), attributes: [.posixPermissions: 0o600])
            return
        }
        let key = rec.protectionClass > 0
            ? try keybag.unwrap(Data(wrapped.dropFirst(4)), protectionClass: rec.protectionClass)
            : try keybag.unwrapClassPrefixed(wrapped)
        try BackupAES.decryptFile(at: source, to: destination, key: key, size: rec.size)
    }

    /// A private, decrypted copy of a file, kept until the archive closes.
    func extractToWork(_ e: Entry) throws -> URL {
        let dest = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent((e.relativePath as NSString).lastPathComponent)
        try extract(e, to: dest)
        return dest
    }

    /// Extracts an SQLite database together with its -wal/-shm files so recent changes are
    /// included. Returns nil when the backup doesn't contain it.
    func extractDatabase(domain: String, path: String) throws -> URL? {
        guard let main = entry(domain: domain, path: path), main.isFile else { return nil }
        let dir = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let name = (path as NSString).lastPathComponent
        try extract(main, to: dir.appendingPathComponent(name))
        for suffix in ["-wal", "-shm"] {
            if let side = entry(domain: domain, path: path + suffix), side.isFile {
                try? extract(side, to: dir.appendingPathComponent(name + suffix))
            }
        }
        return dir.appendingPathComponent(name)
    }

    /// Total size of each domain's files as stored on disk (close to the real size; encrypted
    /// files carry up to 16 bytes of padding).
    func domainSizes() -> [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        var out: [String: Int64] = [:]
        try? manifest.query("SELECT fileID, domain FROM Files WHERE flags = 1") { r in
            guard let id = r.string(0), let domain = r.string(1), id.count == 40 else { return }
            let url = info.url.appendingPathComponent(String(id.prefix(2))).appendingPathComponent(id)
            var st = stat()
            if stat(url.path, &st) == 0 { out[domain, default: 0] += Int64(st.st_size) }
        }
        return out
    }
}

/// Optionally remembers a backup password in the user's login Keychain (their choice).
enum BackupPasswordStore {
    private static let service = "DiskScout iPhone backup password"

    static func save(_ password: String, for udid: String) {
        delete(for: udid)
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: Data(password.utf8),
        ]
        SecItemAdd(item as CFDictionary, nil)
    }

    static func load(for udid: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: udid,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for udid: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: udid]
        SecItemDelete(query as CFDictionary)
    }
}
