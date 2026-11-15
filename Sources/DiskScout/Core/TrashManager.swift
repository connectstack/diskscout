import Foundation
import AppKit

struct TrashRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let name: String
    let originalPath: String
    let trashedPath: String?
    let size: Int64
    let date: Date
    let batchID: UUID
    var restored: Bool = false
    /// The trashed item's file-system identity, so Put Back can't restore a different file that
    /// later took the same name in the Trash.
    var fileNumber: UInt64? = nil

    var originalURL: URL { URL(fileURLWithPath: originalPath) }
    var canPutBack: Bool { !restored && trashedPath != nil }
}

enum TrashError: LocalizedError {
    case alreadyExists(String)
    case missingInTrash(String)
    case emptyTrashFailed(String)
    /// macOS refused the move and Finder couldn't be asked to do it either.
    case permissionDenied(name: String, finderMessage: String?)

    var errorDescription: String? {
        switch self {
        case .alreadyExists(let p): return "Something already exists at \(p)."
        case .missingInTrash(let n): return "“\(n)” is no longer in the Trash."
        case .emptyTrashFailed(let m): return m
        case .permissionDenied(let n, let finder):
            var m = "macOS wouldn't let DiskScout move “\(n)” — it protects other apps' data unless DiskScout has Full Disk Access."
            if let finder { m += " Finder couldn't be asked to do it instead: \(finder)" }
            return m
        }
    }

    var isPermission: Bool { if case .permissionDenied = self { return true }; return false }
}

@MainActor
final class TrashManager: ObservableObject {
    @Published private(set) var history: [TrashRecord] = []
    @Published private(set) var lifetimeFreed: Int64 = 0

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskScout", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("history.json")
    }()

    init() { load() }

    // MARK: - Actions

    /// Moves a file to the Trash and records it. Throws on failure.
    func trash(url: URL, name: String, size: Int64, batchID: UUID) throws -> TrashRecord {
        var resulting: NSURL?
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        } catch let error as NSError where Self.isPermissionError(error) {
            // Without Full Disk Access, macOS (14+) blocks apps from moving other apps' containers
            // and a few other protected folders. Finder is always allowed to, so hand the move to it.
            do {
                resulting = try Self.finderTrash(url) as NSURL?
            } catch let finderError as TrashError {
                throw finderError
            } catch {
                throw TrashError.permissionDenied(name: name, finderMessage: error.localizedDescription)
            }
        }
        var record = TrashRecord(id: UUID(), name: name, originalPath: url.path, trashedPath: resulting?.path,
                                 size: size, date: Date(), batchID: batchID)
        if let trashed = resulting?.path {
            record.fileNumber = ((try? FileManager.default.attributesOfItem(atPath: trashed))?[.systemFileNumber] as? NSNumber)?.uint64Value
        }
        history.insert(record, at: 0)
        if history.count > 500 { history.removeLast(history.count - 500) }
        lifetimeFreed += size
        save()
        return record
    }

    /// Counts space freed somewhere without a Trash (a connected iPhone) towards the lifetime total.
    func recordFreed(_ bytes: Int64) {
        guard bytes > 0 else { return }
        lifetimeFreed += bytes
        save()
    }

    func putBack(_ record: TrashRecord) throws {
        guard let trashed = record.trashedPath else { throw TrashError.missingInTrash(record.name) }
        let fm = FileManager.default
        guard fm.fileExists(atPath: trashed) else { throw TrashError.missingInTrash(record.name) }
        if let expected = record.fileNumber {
            let actual = ((try? fm.attributesOfItem(atPath: trashed))?[.systemFileNumber] as? NSNumber)?.uint64Value
            // Same name, different file: the original was emptied from the Trash and another took its place.
            guard actual == expected else { throw TrashError.missingInTrash(record.name) }
        }
        if fm.fileExists(atPath: record.originalPath) { throw TrashError.alreadyExists(record.originalPath) }
        try fm.createDirectory(at: record.originalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(atPath: trashed, toPath: record.originalPath)
        if let i = history.firstIndex(where: { $0.id == record.id }) {
            history[i].restored = true
        }
        lifetimeFreed = max(0, lifetimeFreed - record.size)
        save()
    }

    func records(inBatch id: UUID) -> [TrashRecord] {
        history.filter { $0.batchID == id }
    }

    /// Restore a whole batch. Returns the number restored and failures.
    func putBack(batch id: UUID) -> (restored: Int, failures: [String]) {
        var restored = 0
        var failures: [String] = []
        for r in records(inBatch: id) where r.canPutBack {
            do { try putBack(r); restored += 1 } catch { failures.append("\(r.name): \(error.localizedDescription)") }
        }
        return (restored, failures)
    }

    /// Asks Finder to empty the Trash (so the user gets the familiar behaviour and sound).
    nonisolated static func isPermissionError(_ e: NSError) -> Bool {
        if e.domain == NSCocoaErrorDomain {
            return e.code == NSFileWriteNoPermissionError || e.code == NSFileReadNoPermissionError
        }
        if e.domain == NSPOSIXErrorDomain { return e.code == Int(EPERM) || e.code == Int(EACCES) }
        if let underlying = e.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermissionError(underlying) }
        return false
    }

    /// Asks Finder to move the item to the Trash. Returns where it ended up.
    static func finderTrash(_ url: URL) throws -> URL {
        let escaped = url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = """
        tell application "Finder"
            set theItem to (POSIX file "\(escaped)") as alias
            set trashed to delete theItem
            return POSIX path of (trashed as alias)
        end tell
        """
        var err: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&err)
        if let err {
            let code = (err[NSAppleScript.errorNumber] as? Int) ?? 0
            var msg = (err[NSAppleScript.errorMessage] as? String) ?? "Finder returned an error."
            if code == -1743 || msg.localizedCaseInsensitiveContains("not allowed") {
                msg = "DiskScout isn't allowed to control Finder (System Settings → Privacy & Security → Automation)."
            }
            throw TrashError.permissionDenied(name: url.lastPathComponent, finderMessage: msg)
        }
        guard let path = result?.stringValue, !path.isEmpty else {
            throw TrashError.permissionDenied(name: url.lastPathComponent, finderMessage: "Finder didn't say where it put the item.")
        }
        // Finder returns a trailing slash for folders.
        return URL(fileURLWithPath: path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path)
    }

    func emptyTrash() throws {
        let script = NSAppleScript(source: "tell application \"Finder\" to empty trash")
        var err: NSDictionary?
        script?.executeAndReturnError(&err)
        if let err {
            let msg = (err[NSAppleScript.errorMessage] as? String) ?? "Finder refused to empty the Trash."
            throw TrashError.emptyTrashFailed(msg + "\n\nYou can also empty it from the Finder's Dock icon.")
        }
        // Everything in history is now gone for good.
        for i in history.indices where !history[i].restored {
            history[i] = TrashRecord(id: history[i].id, name: history[i].name, originalPath: history[i].originalPath,
                                     trashedPath: nil, size: history[i].size, date: history[i].date, batchID: history[i].batchID, restored: false)
        }
        save()
    }

    func clearHistory() {
        history.removeAll()
        save()
    }

    // MARK: - Persistence

    private struct Store: Codable {
        var history: [TrashRecord]
        var lifetimeFreed: Int64
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        history = store.history
        lifetimeFreed = store.lifetimeFreed
    }

    private func save() {
        let store = Store(history: history, lifetimeFreed: lifetimeFreed)
        if let data = try? JSONEncoder().encode(store) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }
}
