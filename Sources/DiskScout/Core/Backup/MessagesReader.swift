import Foundation

// iMessage and SMS. On a Mac: ~/Library/Messages/chat.db (kept current by Messages in iCloud or
// Text Message Forwarding). In an iPhone backup: HomeDomain › Library/SMS/sms.db. Same schema.

final class MessagesStore: ConversationStore, @unchecked Sendable {
    static let macDatabasePath = "Library/Messages/chat.db"
    static let backupSource = (domain: "HomeDomain", path: "Library/SMS/sms.db")
    static let backupAttachmentDomain = "MediaDomain"

    enum Failure: LocalizedError {
        case notMessages
        var errorDescription: String? { "This doesn't look like a Messages database." }
    }

    let service = MessagingService.messages
    private let db: SQLiteDB
    private let contacts: [String: String]
    private let attachmentFile: @Sendable (String) throws -> URL?
    private let messageCols: Set<String>
    private let joinHasDate: Bool
    private let lock = NSLock()
    /// Thread id → the chat rows it merges (iMessage and SMS with the same person are separate rows).
    private var chatRows: [String: [Int64]] = [:]
    private var threadOfChat: [Int64: String] = [:]

    /// `attachmentFile` turns a stored path ("~/Library/Messages/Attachments/…") into a readable file.
    init(databaseAt url: URL, contacts: [String: String], attachmentFile: @escaping @Sendable (String) throws -> URL?) throws {
        db = try SQLiteDB(path: url.path)
        guard db.tables().isSuperset(of: ["chat", "message", "chat_message_join", "handle"]) else { throw Failure.notMessages }
        self.contacts = contacts
        self.attachmentFile = attachmentFile
        messageCols = db.columns("message")
        joinHasDate = db.columns("chat_message_join").contains("message_date")
    }

    private func name(for handle: String) -> String {
        ContactsReader.name(for: handle, in: contacts) ?? handle
    }

    private var hasAttachments: Bool { db.tables().isSuperset(of: ["attachment", "message_attachment_join"]) }

    func threads() throws -> [ChatThread] {
        struct Row { var ids: [Int64]; var identifier: String; var displayName: String?; var isGroup: Bool; var count: Int; var last: Date? }
        var rows: [String: Row] = [:]
        let dateExpr = joinHasDate ? "MAX(j.message_date)" : "MAX(m.date)"
        let messageJoin = joinHasDate ? "" : "JOIN message m ON m.ROWID = j.message_id"
        try db.query("""
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.style, COUNT(j.message_id), \(dateExpr)
            FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID \(messageJoin) GROUP BY c.ROWID
            """) { r in
            let id = r.int64(0)
            let identifier = r.string(1) ?? "chat\(id)"
            let isGroup = r.int(3) == 43
            // Group chats stay separate; one-to-one chats with the same person merge.
            let key = isGroup ? "g\(id)" : "p:" + identifier.lowercased()
            var row = rows[key] ?? Row(ids: [], identifier: identifier, displayName: nil, isGroup: isGroup, count: 0, last: nil)
            row.ids.append(id)
            row.count += r.int(4)
            if let name = r.string(2), !name.isEmpty { row.displayName = name }
            if let d = r.appleDate(5), d > (row.last ?? .distantPast) { row.last = d }
            rows[key] = row
        }

        var media: [Int64: (Int, Int64)] = [:]
        if hasAttachments {
            try db.query("""
                SELECT j.chat_id, COUNT(a.ROWID), SUM(COALESCE(a.total_bytes, 0)) FROM chat_message_join j
                JOIN message_attachment_join maj ON maj.message_id = j.message_id
                JOIN attachment a ON a.ROWID = maj.attachment_id GROUP BY j.chat_id
                """) { media[$0.int64(0)] = ($0.int(1), max(0, $0.int64(2))) }
        }
        var members: [Int64: [String]] = [:]
        if db.tables().contains("chat_handle_join") {
            try db.query("SELECT chj.chat_id, h.id FROM chat_handle_join chj JOIN handle h ON h.ROWID = chj.handle_id") { r in
                if let h = r.string(1) { members[r.int64(0), default: []].append(h) }
            }
        }

        var out: [ChatThread] = []
        var rowsByThread: [String: [Int64]] = [:], threadByRow: [Int64: String] = [:]
        for (key, row) in rows where row.count > 0 {
            rowsByThread[key] = row.ids
            for id in row.ids { threadByRow[id] = key }
            let title: String
            var detail: String? = nil
            if let n = row.displayName {
                title = n
            } else if row.isGroup {
                let names = (members[row.ids[0]] ?? []).map(name(for:))
                title = names.isEmpty ? "Group" : (names.count > 3 ? names.prefix(3).joined(separator: ", ") + " & \(names.count - 3) more" : names.joined(separator: ", "))
            } else {
                title = name(for: row.identifier)
                if title != row.identifier { detail = row.identifier }
            }
            let m = row.ids.reduce((0, Int64(0))) { acc, id in (acc.0 + (media[id]?.0 ?? 0), acc.1 + (media[id]?.1 ?? 0)) }
            out.append(ChatThread(id: key, service: .messages, title: title, detail: detail, isGroup: row.isGroup, lastDate: row.last,
                                  messageCount: row.count, mediaCount: m.0, mediaBytes: m.1))
        }
        lock.lock(); chatRows = rowsByThread; threadOfChat = threadByRow; lock.unlock()
        return out.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    private func rows(for thread: String) throws -> [Int64] {
        lock.lock()
        let cached = chatRows[thread]
        lock.unlock()
        if let cached { return cached }
        _ = try threads()
        lock.lock(); defer { lock.unlock() }
        return chatRows[thread] ?? []
    }

    private func col(_ name: String) -> String { messageCols.contains(name) ? "m.\(name)" : "NULL" }

    func messages(in thread: String, limit: Int) throws -> [ChatMessage] {
        let ids = try rows(for: thread)
        guard !ids.isEmpty else { return [] }
        let marks = ids.map { _ in "?" }.joined(separator: ",")

        var attachments: [Int64: [ChatAttachment]] = [:]
        if hasAttachments {
            try db.query("""
                SELECT maj.message_id, a.filename, a.mime_type, a.transfer_name, a.total_bytes FROM message_attachment_join maj
                JOIN attachment a ON a.ROWID = maj.attachment_id
                WHERE maj.message_id IN (SELECT message_id FROM chat_message_join WHERE chat_id IN (\(marks)))
                """, ids) { r in
                let file = r.string(1), title = r.string(3) ?? file.map { ($0 as NSString).lastPathComponent }
                attachments[r.int64(0), default: []].append(
                    ChatAttachment(kind: .init(mimeType: r.string(2), fileName: title), title: title, size: r.isNull(4) ? 0 : max(0, r.int64(4)), locator: file))
            }
        }

        var out: [ChatMessage] = []
        try db.query("""
            SELECT m.ROWID, m.date, m.is_from_me, m.text, \(col("attributedBody")), h.id, \(col("item_type")), \(col("associated_message_type")), \(col("group_title"))
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id IN (\(marks)) ORDER BY m.date DESC LIMIT \(max(1, limit))
            """, ids) { r in
            // Tapbacks ("Liked …") are stored as messages; leave them out.
            if !r.isNull(7), r.int(7) >= 1000 { return }
            let id = r.int64(0)
            let fromMe = r.int(2) != 0
            let isSystem = !r.isNull(6) && r.int(6) != 0
            var text = Self.clean(r.string(3)) ?? r.data(4).flatMap(Self.text(fromAttributedBody:)).flatMap(Self.clean)
            if isSystem, text == nil { text = r.string(8).map { "Named the conversation “\($0)”" } ?? "The group changed" }
            let files = attachments[id] ?? []
            guard text != nil || !files.isEmpty else { return }
            out.append(ChatMessage(id: String(id), date: r.appleDate(1), fromMe: fromMe,
                                   sender: fromMe ? nil : r.string(5).map(name(for:)), text: text, isSystem: isSystem, attachments: files))
        }
        return out.reversed()
    }

    func forEachText(_ body: (String, String, Date?, String?, String) -> Void) throws {
        _ = try rows(for: "")
        lock.lock()
        let map = threadOfChat
        lock.unlock()
        try db.query("""
            SELECT j.chat_id, m.ROWID, m.date, m.is_from_me, m.text, \(col("attributedBody")), h.id, \(col("associated_message_type"))
            FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id LEFT JOIN handle h ON h.ROWID = m.handle_id
            """) { r in
            if !r.isNull(7), r.int(7) >= 1000 { return }
            guard let thread = map[r.int64(0)],
                  let text = Self.clean(r.string(4)) ?? r.data(5).flatMap(Self.text(fromAttributedBody:)).flatMap(Self.clean) else { return }
            body(thread, String(r.int64(1)), r.appleDate(2), r.int(3) != 0 ? "Me" : r.string(6).map(name(for:)), text)
        }
    }

    func file(for attachment: ChatAttachment) throws -> URL? {
        try attachment.locator.flatMap(attachmentFile)
    }

    /// Drops the placeholder characters Messages uses where attachments sit in the text.
    static func clean(_ s: String?) -> String? {
        guard let s else { return nil }
        let t = s.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Newer versions keep the text only in `attributedBody`, an NSAttributedString in Apple's
    /// "typedstream" format. This reads the string straight out of the bytes: after the NSString
    /// class marker comes a `+` and a length (1 byte, or 0x81 + 2 bytes, or 0x82 + 4 bytes, little
    /// endian), then UTF-8. Nothing is unarchived, so a malformed blob can only yield nil.
    static func text(fromAttributedBody data: Data) -> String? {
        let bytes = [UInt8](data)
        let marker = Array("NSString".utf8)
        guard bytes.count > marker.count + 4 else { return nil }
        var start: Int?
        var i = 0
        while i <= bytes.count - marker.count {
            if bytes[i] == marker[0], Array(bytes[i ..< i + marker.count]) == marker { start = i + marker.count; break }
            i += 1
        }
        guard var p = start else { return nil }
        let limit = min(p + 8, bytes.count)
        while p < limit, bytes[p] != 0x2B { p += 1 }
        guard p < limit else { return nil }
        p += 1
        guard p < bytes.count else { return nil }
        var length = Int(bytes[p]); p += 1
        if length == 0x81 {
            guard p + 2 <= bytes.count else { return nil }
            length = Int(bytes[p]) | Int(bytes[p + 1]) << 8; p += 2
        } else if length == 0x82 {
            guard p + 4 <= bytes.count else { return nil }
            length = Int(bytes[p]) | Int(bytes[p + 1]) << 8 | Int(bytes[p + 2]) << 16 | Int(bytes[p + 3]) << 24; p += 4
        }
        guard length > 0, p + length <= bytes.count else { return nil }
        return String(bytes: bytes[p ..< p + length], encoding: .utf8)
    }
}
