import Foundation

// WhatsApp keeps its chats in ChatStorage.sqlite, inside its App Group container. In a backup
// that's the `AppDomainGroup-group.net.whatsapp.WhatsApp.shared` domain; media sits next to it
// under `Message/Media/…`.

struct WAChat: Identifiable, Hashable {
    let id: Int64
    let name: String
    let jid: String
    let isGroup: Bool
    let lastMessageDate: Date?
    var messageCount: Int
    var mediaCount: Int
    var mediaBytes: Int64
    let archived: Bool
}

struct WAMessage: Identifiable, Hashable {
    enum Kind: Int {
        case text = 0, image = 1, video = 2, audio = 3, contact = 4, location = 5, system = 6, link = 7, document = 8, gif = 11, sticker = 15
        case other = -1

        var label: String {
            switch self {
            case .text: return "Message"
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return "Voice message"
            case .contact: return "Contact"
            case .location: return "Location"
            case .system: return "Chat event"
            case .link: return "Link"
            case .document: return "Document"
            case .gif: return "GIF"
            case .sticker: return "Sticker"
            case .other: return "Attachment"
            }
        }

        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .video, .gif: return "video"
            case .audio: return "waveform"
            case .contact: return "person.crop.circle"
            case .location: return "mappin.and.ellipse"
            case .document: return "doc"
            case .sticker: return "face.smiling"
            case .link: return "link"
            default: return "paperclip"
            }
        }
    }

    let id: Int64
    let date: Date?
    let fromMe: Bool
    let sender: String?
    let text: String?
    let kind: Kind
    /// Path of the attachment inside the backup domain ("Message/Media/…").
    let mediaPath: String?
    let mediaSize: Int64
    let mediaTitle: String?
}

final class WhatsAppReader {
    /// Backup domains for WhatsApp and WhatsApp Business.
    static let sources: [(domain: String, name: String)] = [
        ("AppDomainGroup-group.net.whatsapp.WhatsApp.shared", "WhatsApp"),
        ("AppDomainGroup-group.net.whatsapp.WhatsAppSMB.shared", "WhatsApp Business"),
    ]
    static let databasePath = "ChatStorage.sqlite"

    enum Failure: LocalizedError {
        case notWhatsApp
        var errorDescription: String? { "This doesn't look like a WhatsApp chat database." }
    }

    private let db: SQLiteDB
    private let messageColumns: Set<String>
    private let chatColumns: Set<String>
    private let hasMedia: Bool
    private let hasMembers: Bool
    private let hasPushNames: Bool

    init(databaseAt url: URL) throws {
        db = try SQLiteDB(path: url.path)
        let tables = db.tables()
        guard tables.contains("ZWACHATSESSION"), tables.contains("ZWAMESSAGE") else { throw Failure.notWhatsApp }
        messageColumns = db.columns("ZWAMESSAGE")
        chatColumns = db.columns("ZWACHATSESSION")
        hasMedia = tables.contains("ZWAMEDIAITEM") && db.columns("ZWAMEDIAITEM").isSuperset(of: ["ZMESSAGE", "ZFILESIZE"])
        hasMembers = tables.contains("ZWAGROUPMEMBER")
        hasPushNames = tables.contains("ZWAPROFILEPUSHNAME")
    }

    private func col(_ name: String, in columns: Set<String>, as alias: String? = nil, table: String) -> String {
        columns.contains(name) ? "\(table).\(name)" : "NULL"
    }

    func chats() throws -> [WAChat] {
        var counts: [Int64: Int] = [:]
        try db.query("SELECT ZCHATSESSION, COUNT(*) FROM ZWAMESSAGE GROUP BY ZCHATSESSION") { counts[$0.int64(0)] = $0.int(1) }
        var media: [Int64: (Int, Int64)] = [:]
        if hasMedia {
            try db.query("""
                SELECT m.ZCHATSESSION, COUNT(mi.Z_PK), SUM(COALESCE(mi.ZFILESIZE, 0))
                FROM ZWAMEDIAITEM mi JOIN ZWAMESSAGE m ON mi.ZMESSAGE = m.Z_PK GROUP BY m.ZCHATSESSION
                """) { media[$0.int64(0)] = ($0.int(1), $0.int64(2)) }
        }
        let c = chatColumns
        let sql = """
            SELECT s.Z_PK, \(col("ZPARTNERNAME", in: c, table: "s")), \(col("ZCONTACTJID", in: c, table: "s")),
                   \(col("ZLASTMESSAGEDATE", in: c, table: "s")), \(col("ZSESSIONTYPE", in: c, table: "s")),
                   \(col("ZARCHIVED", in: c, table: "s")), \(col("ZREMOVED", in: c, table: "s"))
            FROM ZWACHATSESSION s
            """
        var out: [WAChat] = []
        try db.query(sql) { r in
            let id = r.int64(0)
            let jid = r.string(2) ?? ""
            guard !jid.hasPrefix("status@"), r.isNull(6) || r.int(6) == 0 else { return }  // skip Status updates and removed chats
            let count = counts[id] ?? 0
            guard count > 0 else { return }
            let name = r.string(1).flatMap { $0.isEmpty ? nil : $0 } ?? Self.readable(jid: jid)
            let m = media[id] ?? (0, 0)
            out.append(WAChat(id: id, name: name, jid: jid, isGroup: jid.hasSuffix("@g.us") || (!r.isNull(4) && r.int(4) == 1),
                              lastMessageDate: r.appleDate(3), messageCount: count, mediaCount: m.0, mediaBytes: m.1,
                              archived: !r.isNull(5) && r.int(5) != 0))
        }
        return out.sorted { ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast) }
    }

    /// Messages in a chat, oldest first. `limit` most recent ones.
    func messages(in chat: Int64, limit: Int = 2000) throws -> [WAMessage] {
        try fetchMessages(where: "m.ZCHATSESSION = ?", bindings: [chat], limit: limit).reversed()
    }

    /// Messages whose text contains `query`, newest first, with their chat ids.
    func search(_ query: String, limit: Int = 300) throws -> [(chat: Int64, message: WAMessage)] {
        guard messageColumns.contains("ZTEXT") else { return [] }
        var chatOf: [Int64: Int64] = [:]
        let msgs = try fetchMessages(where: "m.ZTEXT LIKE ?", bindings: ["%" + query + "%"], limit: limit, chatOf: &chatOf)
        return msgs.compactMap { m in chatOf[m.id].map { ($0, m) } }
    }

    private func fetchMessages(where clause: String, bindings: [Any?], limit: Int) throws -> [WAMessage] {
        var ignored: [Int64: Int64] = [:]
        return try fetchMessages(where: clause, bindings: bindings, limit: limit, chatOf: &ignored)
    }

    private func fetchMessages(where clause: String, bindings: [Any?], limit: Int, chatOf: inout [Int64: Int64]) throws -> [WAMessage] {
        let m = messageColumns
        let memberJoin = hasMembers && m.contains("ZGROUPMEMBER") ? "LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER" : ""
        let memberName = hasMembers && m.contains("ZGROUPMEMBER") ? "COALESCE(g.ZCONTACTNAME, g.ZMEMBERJID)" : "NULL"
        let mediaJoin = hasMedia && m.contains("ZMEDIAITEM") ? "LEFT JOIN ZWAMEDIAITEM mi ON mi.Z_PK = m.ZMEDIAITEM" : (hasMedia ? "LEFT JOIN ZWAMEDIAITEM mi ON mi.ZMESSAGE = m.Z_PK" : "")
        let mediaCols = hasMedia ? "mi.ZMEDIALOCALPATH, mi.ZFILESIZE, mi.ZTITLE" : "NULL, NULL, NULL"
        let sql = """
            SELECT m.Z_PK, \(col("ZMESSAGEDATE", in: m, table: "m")), \(col("ZISFROMME", in: m, table: "m")),
                   \(col("ZTEXT", in: m, table: "m")), \(col("ZMESSAGETYPE", in: m, table: "m")),
                   \(memberName), \(col("ZFROMJID", in: m, table: "m")), \(mediaCols), m.ZCHATSESSION
            FROM ZWAMESSAGE m \(memberJoin) \(mediaJoin)
            WHERE \(clause)
            ORDER BY \(m.contains("ZMESSAGEDATE") ? "m.ZMESSAGEDATE" : "m.Z_PK") DESC
            LIMIT \(max(1, limit))
            """
        var out: [WAMessage] = []
        try db.query(sql, bindings) { r in
            let fromMe = !r.isNull(2) && r.int(2) != 0
            let sender = fromMe ? nil : (r.string(5) ?? r.string(6).map(Self.readable(jid:)))
            let kind = r.isNull(4) ? WAMessage.Kind.text : (WAMessage.Kind(rawValue: r.int(4)) ?? .other)
            let msg = WAMessage(id: r.int64(0), date: r.appleDate(1), fromMe: fromMe, sender: sender,
                                text: r.string(3), kind: kind,
                                mediaPath: r.string(7).map(Self.backupPath(forMedia:)), mediaSize: r.isNull(8) ? 0 : r.int64(8),
                                mediaTitle: r.string(9))
            chatOf[msg.id] = r.int64(10)
            out.append(msg)
        }
        return out
    }

    /// Streams every message that has text (for the search index), without loading them all at once.
    func forEachText(_ body: (_ chat: Int64, _ id: Int64, _ date: Date?, _ sender: String?, _ text: String) -> Void) throws {
        guard messageColumns.contains("ZTEXT") else { return }
        let m = messageColumns
        let memberJoin = hasMembers && m.contains("ZGROUPMEMBER") ? "LEFT JOIN ZWAGROUPMEMBER g ON g.Z_PK = m.ZGROUPMEMBER" : ""
        let memberName = hasMembers && m.contains("ZGROUPMEMBER") ? "COALESCE(g.ZCONTACTNAME, g.ZMEMBERJID)" : "NULL"
        try db.query("""
            SELECT m.ZCHATSESSION, m.Z_PK, \(col("ZMESSAGEDATE", in: m, table: "m")), \(col("ZISFROMME", in: m, table: "m")), \(memberName), m.ZTEXT
            FROM ZWAMESSAGE m \(memberJoin) WHERE m.ZTEXT IS NOT NULL AND m.ZTEXT != ''
            """) { r in
            guard let text = r.string(5) else { return }
            let fromMe = !r.isNull(3) && r.int(3) != 0
            body(r.int64(0), r.int64(1), r.appleDate(2), fromMe ? "Me" : r.string(4), text)
        }
    }

    /// "919812345678@s.whatsapp.net" → "+91 98123 45678"-ish readable text.
    static func readable(jid: String) -> String {
        let user = jid.split(separator: "@").first.map(String.init) ?? jid
        if jid.hasSuffix("@g.us") { return "Group" }
        return user.allSatisfy(\.isNumber) ? "+" + user : user
    }

    /// Media paths are stored relative to WhatsApp's "Message" folder (sometimes with a leading slash
    /// or the whole container path). Normalise to the path inside the backup domain.
    static func backupPath(forMedia stored: String) -> String {
        if let r = stored.range(of: "/Message/") { return "Message/" + stored[r.upperBound...] }
        let trimmed = stored.hasPrefix("/") ? String(stored.dropFirst()) : stored
        return trimmed.hasPrefix("Message/") ? trimmed : "Message/" + trimmed
    }

    /// A plain-text transcript of a chat.
    static func transcript(of chat: WAChat, messages: [WAMessage]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["\(chat.name) — WhatsApp chat exported by DiskScout", ""]
        for m in messages {
            let when = m.date.map { f.string(from: $0) } ?? "?"
            let who = m.fromMe ? "Me" : (m.sender ?? chat.name)
            var body = m.text ?? ""
            if m.kind != .text && m.kind != .system {
                let size = m.mediaSize > 0 ? " · " + m.mediaSize.bytesString : ""
                let attachment = "<\(m.kind.label)\(m.mediaTitle.map { ": " + $0 } ?? "")\(size)>"
                body = body.isEmpty ? attachment : body + " " + attachment
            }
            lines.append(m.kind == .system ? "[\(when)] \(body)" : "[\(when)] \(who): \(body)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
