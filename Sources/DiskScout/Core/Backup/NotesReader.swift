import Foundation

// Apple Notes keeps notes in NoteStore.sqlite (App Group `group.com.apple.notes`). Each note's
// body is a gzip-compressed protobuf: NoteStoreProto › Document (field 2) › Note (field 3) ›
// note_text (field 2). Locked notes are encrypted with the Notes password and stay locked.

struct NoteItem: Identifiable, Hashable {
    let id: Int64
    let title: String
    let snippet: String?
    let folder: String?
    let created: Date?
    let modified: Date?
    let isLocked: Bool
    let isPinned: Bool
    let inRecentlyDeleted: Bool
}

final class NotesReader {
    static let domain = "AppDomainGroup-group.com.apple.notes"
    static let databasePath = "NoteStore.sqlite"

    enum Failure: LocalizedError {
        case notNotes
        var errorDescription: String? { "This doesn't look like an Apple Notes database." }
    }

    private let db: SQLiteDB
    private let cols: Set<String>

    init(databaseAt url: URL) throws {
        db = try SQLiteDB(path: url.path)
        guard db.tables().contains("ZICCLOUDSYNCINGOBJECT") else { throw Failure.notNotes }
        cols = db.columns("ZICCLOUDSYNCINGOBJECT")
        guard cols.contains("ZNOTEDATA") else { throw Failure.notNotes }
    }

    private func first(_ names: [String]) -> String? { names.first(where: cols.contains) }

    func notes() throws -> [NoteItem] {
        func c(_ name: String?, _ table: String = "n") -> String { name.map { "\(table).\($0)" } ?? "NULL" }
        let title = first(["ZTITLE1", "ZTITLE"])
        let created = first(["ZCREATIONDATE3", "ZCREATIONDATE2", "ZCREATIONDATE1", "ZCREATIONDATE"])
        let modified = first(["ZMODIFICATIONDATE1", "ZMODIFICATIONDATE"])
        let folderTitle = first(["ZTITLE2"])
        let hasFolder = cols.contains("ZFOLDER")
        let sql = """
            SELECT n.Z_PK, \(c(title)), \(c(first(["ZSNIPPET"]))), \(hasFolder ? c(folderTitle, "f") : "NULL"),
                   \(c(created)), \(c(modified)), \(c(first(["ZISPASSWORDPROTECTED"]))), \(c(first(["ZISPINNED"]))),
                   \(hasFolder ? c(first(["ZFOLDERTYPE"]), "f") : "NULL"), \(c(first(["ZMARKEDFORDELETION"])))
            FROM ZICCLOUDSYNCINGOBJECT n
            \(hasFolder ? "LEFT JOIN ZICCLOUDSYNCINGOBJECT f ON f.Z_PK = n.ZFOLDER" : "")
            WHERE n.ZNOTEDATA IS NOT NULL
            """
        var out: [NoteItem] = []
        try db.query(sql) { r in
            if !r.isNull(9) && r.int(9) != 0 { return }    // already purged
            out.append(NoteItem(
                id: r.int64(0),
                title: r.string(1).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled note",
                snippet: r.string(2),
                folder: r.string(3),
                created: r.appleDate(4),
                modified: r.appleDate(5),
                isLocked: !r.isNull(6) && r.int(6) != 0,
                isPinned: !r.isNull(7) && r.int(7) != 0,
                inRecentlyDeleted: !r.isNull(8) && r.int(8) == 1))
        }
        return out.sorted { ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
    }

    /// The note's text, or nil for locked or unreadable notes. Attachments show as "[attachment]".
    func body(of note: Int64) -> String? {
        var blob: Data?
        try? db.query("""
            SELECT d.ZDATA FROM ZICCLOUDSYNCINGOBJECT n JOIN ZICNOTEDATA d ON d.Z_PK = n.ZNOTEDATA WHERE n.Z_PK = ?
            """, [note]) { blob = $0.data(0) }
        return blob.flatMap(NoteProtobuf.text(fromNoteData:))
    }
}

enum NoteProtobuf {
    static func text(fromNoteData data: Data) -> String? {
        guard let raw = data.starts(with: [0x1F, 0x8B]) ? gunzip(data) : data,
              let document = field(2, in: raw), let note = field(3, in: document), let text = field(2, in: note),
              let s = String(data: text, encoding: .utf8) else { return nil }
        return s.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]")
    }

    /// The first length-delimited occurrence of `number` in a protobuf message.
    static func field(_ number: Int, in data: Data) -> Data? {
        let bytes = [UInt8](data)
        var i = 0
        func varint() -> UInt64? {
            var result: UInt64 = 0, shift: UInt64 = 0
            while i < bytes.count {
                let b = bytes[i]; i += 1
                result |= UInt64(b & 0x7F) << shift
                if b & 0x80 == 0 { return result }
                shift += 7
                if shift > 63 { return nil }
            }
            return nil
        }
        while i < bytes.count {
            guard let key = varint() else { return nil }
            let fieldNumber = Int(key >> 3), wire = Int(key & 7)
            switch wire {
            case 0: guard varint() != nil else { return nil }
            case 1: i += 8
            case 2:
                guard let len = varint(), i <= bytes.count, len <= UInt64(bytes.count - i) else { return nil }
                if fieldNumber == number { return Data(bytes[i ..< i + Int(len)]) }
                i += Int(len)
            case 5: i += 4
            default: return nil
            }
        }
        return nil
    }

    /// gzip → raw DEFLATE (skipping the gzip header and trailer) → inflate.
    static func gunzip(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 18, b[0] == 0x1F, b[1] == 0x8B, b[2] == 8 else { return nil }
        let flags = b[3]
        var i = 10
        if flags & 0x04 != 0 { guard i + 2 <= b.count else { return nil }; i += 2 + (Int(b[i]) | Int(b[i + 1]) << 8) }
        if flags & 0x08 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x10 != 0 { while i < b.count && b[i] != 0 { i += 1 }; i += 1 }
        if flags & 0x02 != 0 { i += 2 }
        guard i < b.count - 8 else { return nil }
        let deflated = Data(b[i ..< b.count - 8])
        return try? (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
