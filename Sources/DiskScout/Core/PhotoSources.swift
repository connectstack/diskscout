import Foundation
import SQLite3

/// Which app put each photo and video into the library. iOS records this in the Photos database
/// (`ZADDITIONALASSETATTRIBUTES.ZIMPORTEDBYBUNDLEIDENTIFIER`), which a Mac can read over USB.
struct PhotoSource: Identifiable, Hashable {
    static let unknownID = "unknown"
    static let recentlyDeletedID = "recently-deleted"

    let id: String
    let name: String
    let systemImage: String
    /// A third-party app (as opposed to Camera, screenshots, AirDrop and other parts of iOS).
    let isApp: Bool
    var items: Int = 0
    var bytes: Int64 = 0

    var detail: String {
        switch id {
        case Self.unknownID: return "Older items, or ones synced or imported before iOS noted where they came from."
        case Self.recentlyDeletedID: return "Already deleted, but still taking space for up to 30 days. Empty Recently Deleted in Photos to free it now."
        case "com.apple.camera": return "Taken with the Camera app on this iPhone."
        case "com.apple.replayd": return "Screen recordings. These are often far bigger than they look."
        case "com.apple.springboard": return "Screenshots."
        case "com.apple.sharingd": return "Received with AirDrop."
        case "com.apple.mobileslideshow": return "Edits, duplicates and exports made in Photos."
        default: return isApp ? "Saved to your library by this app. They stay in Photos even if you delete the app." : "Saved by a part of iOS."
        }
    }

    /// Readable name and icon for an importer.
    static func make(bundleID: String, displayName: String?) -> PhotoSource {
        let cleaned = displayName?.trimmingCharacters(in: CharacterSet(charactersIn: "\u{200E}\u{200F}").union(.whitespaces))
        let known: [String: (String, String)] = [
            "com.apple.camera": ("Camera", "camera.fill"),
            "com.apple.replayd": ("Screen recordings", "record.circle"),
            "com.apple.springboard": ("Screenshots", "camera.viewfinder"),
            "com.apple.sharingd": ("AirDrop", "antenna.radiowaves.left.and.right"),
            "com.apple.mobileslideshow": ("Photos edits & exports", "photo.on.rectangle"),
            "com.apple.MobileSMS": ("Messages", "message.fill"),
            "com.apple.mobilesafari": ("Safari", "safari"),
            "com.apple.mobilemail": ("Mail", "envelope.fill"),
            "com.apple.DocumentsApp": ("Files", "folder.fill"),
        ]
        if bundleID.isEmpty { return PhotoSource(id: unknownID, name: "Unknown origin", systemImage: "questionmark.circle", isApp: false) }
        if let k = known[bundleID] { return PhotoSource(id: bundleID, name: k.0, systemImage: k.1, isApp: false) }
        let isApple = bundleID.hasPrefix("com.apple.")
        let name = (cleaned?.isEmpty == false ? cleaned! : nil) ?? (bundleID.split(separator: ".").last.map(String.init) ?? bundleID)
        return PhotoSource(id: bundleID, name: name, systemImage: isApple ? "applelogo" : "app.fill", isApp: !isApple)
    }

    /// "/DCIM/104APPLE/IMG_4805" — one library item, whatever its files' extensions
    /// (a Live Photo's .HEIC and .MOV, its .AAE edits).
    static func assetKey(folder: String, baseName: String) -> String {
        (folder.hasPrefix("/") ? folder : "/" + folder) + "/" + baseName.uppercased()
    }
}

enum PhotoSourceReader {
    struct Asset {
        let key: String
        let importer: String
        let displayName: String?
        let trashed: Bool
    }

    enum ReadError: LocalizedError {
        case open(String), schema
        var errorDescription: String? {
            switch self {
            case .open(let m): return "Couldn't read the Photos database: \(m)"
            case .schema: return "This version of iOS doesn't record which app saved each photo."
            }
        }
    }

    /// Reads a local copy of Photos.sqlite (with its -wal and -shm next to it).
    static func read(databaseAt path: String) throws -> [Asset] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db else {
            throw ReadError.open(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_close(db) }

        func columns(_ table: String) -> Set<String> {
            var stmt: OpaquePointer?
            var out = Set<String>()
            if sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 1) { out.insert(String(cString: c)) }
            }
            sqlite3_finalize(stmt)
            return out
        }
        let extra = columns("ZADDITIONALASSETATTRIBUTES"), asset = columns("ZASSET")
        guard extra.isSuperset(of: ["ZASSET", "ZIMPORTEDBYBUNDLEIDENTIFIER"]),
              asset.isSuperset(of: ["Z_PK", "ZDIRECTORY", "ZFILENAME", "ZTRASHEDSTATE"]) else { throw ReadError.schema }
        let nameColumn = extra.contains("ZIMPORTEDBYDISPLAYNAME") ? "aa.ZIMPORTEDBYDISPLAYNAME" : "NULL"

        let sql = """
            SELECT a.ZDIRECTORY, a.ZFILENAME, aa.ZIMPORTEDBYBUNDLEIDENTIFIER, \(nameColumn), a.ZTRASHEDSTATE
            FROM ZASSET a JOIN ZADDITIONALASSETATTRIBUTES aa ON aa.ZASSET = a.Z_PK
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw ReadError.open(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(stmt) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        var out: [Asset] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let dir = text(0), let file = text(1) else { continue }
            out.append(Asset(key: PhotoSource.assetKey(folder: dir, baseName: (file as NSString).deletingPathExtension),
                             importer: text(2) ?? "", displayName: text(3),
                             trashed: sqlite3_column_int(stmt, 4) != 0))
        }
        return out
    }
}
