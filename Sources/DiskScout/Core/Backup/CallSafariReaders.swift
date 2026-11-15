import Foundation

// MARK: - Call history
// Library/CallHistoryDB/CallHistory.storedata in HomeDomain. Apple only puts it in encrypted backups.

struct CallRecord: Identifiable, Hashable {
    let id: Int64
    let date: Date?
    let duration: Double
    let outgoing: Bool
    let answered: Bool
    let service: String
    let number: String?
    let name: String?
    let location: String?

    var missed: Bool { !outgoing && !answered }
    var direction: String { outgoing ? "Outgoing" : (answered ? "Incoming" : "Missed") }
}

enum CallHistoryReader {
    static let domain = "HomeDomain"
    static let databasePath = "Library/CallHistoryDB/CallHistory.storedata"

    /// `contacts` maps the last 10 digits of a phone number to a name; `appNames` maps CallKit
    /// apps' bundle ids (WhatsApp, Telegram…) to their names.
    static func calls(databaseAt url: URL, contacts: [String: String] = [:], appNames: [String: String] = [:]) throws -> [CallRecord] {
        let db = try SQLiteDB(path: url.path)
        let cols = db.columns("ZCALLRECORD")
        guard !cols.isEmpty else { return [] }
        func c(_ n: String) -> String { cols.contains(n) ? n : "NULL" }
        let sql = """
            SELECT Z_PK, \(c("ZDATE")), \(c("ZDURATION")), \(c("ZORIGINATED")), \(c("ZANSWERED")), \(c("ZCALLTYPE")),
                   \(c("ZSERVICE_PROVIDER")), \(c("ZADDRESS")), \(c("ZNAME")), \(c("ZLOCATION"))
            FROM ZCALLRECORD ORDER BY \(cols.contains("ZDATE") ? "ZDATE" : "Z_PK") DESC
            """
        var out: [CallRecord] = []
        try db.query(sql) { r in
            let provider = r.string(6) ?? "com.apple.Telephony"
            let type = r.isNull(5) ? 1 : r.int(5)
            let number = r.string(7).map { $0.contains("@s.whatsapp.net") ? WhatsAppReader.readable(jid: $0) : $0 }
            let contact = number.flatMap { contacts[ContactsReader.key($0)] }
            let seconds = r.isNull(2) ? 0 : r.double(2)
            out.append(CallRecord(id: r.int64(0), date: r.appleDate(1), duration: seconds.isFinite ? min(max(seconds, 0), 31_536_000) : 0,
                                  outgoing: !r.isNull(3) && r.int(3) != 0, answered: !r.isNull(4) && r.int(4) != 0,
                                  service: serviceName(provider: provider, callType: type, appNames: appNames),
                                  number: number, name: contact ?? r.string(8).flatMap { $0.isEmpty ? nil : $0 },
                                  location: r.string(9).flatMap { $0.isEmpty || $0 == "<<RecentsNumberLocationNotFound>>" ? nil : $0 }))
        }
        return out
    }

    static func serviceName(provider: String, callType: Int, appNames: [String: String]) -> String {
        switch provider {
        case "com.apple.Telephony": return "Phone"
        case "com.apple.FaceTime": return callType == 8 ? "FaceTime Video" : (callType == 16 ? "FaceTime Audio" : "FaceTime")
        default:
            let known = ["net.whatsapp.WhatsApp": "WhatsApp", "net.whatsapp.WhatsAppSMB": "WhatsApp Business", "ph.telegra.Telegraph": "Telegram",
                         "org.whispersystems.signal": "Signal", "com.viber": "Viber", "com.facebook.Messenger": "Messenger",
                         "com.skype.skype": "Skype", "us.zoom.videomeetings": "Zoom", "com.microsoft.skype.teams": "Teams",
                         "com.google.meetings": "Google Meet", "com.burbn.instagram": "Instagram"]
            return appNames[provider] ?? known[provider] ?? provider.split(separator: ".").last.map(String.init)?.capitalized ?? provider
        }
    }

    static func csv(_ calls: [CallRecord]) -> String {
        let iso = ISO8601DateFormatter()
        var rows = ["Date,Direction,Service,Name,Number,Duration (s),Location"]
        for c in calls {
            rows.append([c.date.map { iso.string(from: $0) } ?? "", c.direction, c.service, c.name ?? "", c.number ?? "",
                         String(Int(c.duration.rounded())), c.location ?? ""].map(CSV.field).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

enum ContactsReader {
    static let domain = "HomeDomain"
    static let databasePath = "Library/AddressBook/AddressBook.sqlitedb"

    /// Last 10 digits, so "+91 98123-45678" and "09812345678" match.
    static func key(_ number: String) -> String {
        String(number.filter(\.isNumber).suffix(10))
    }

    /// The name for a phone number or email address, if it's in the contacts map.
    static func name(for handle: String, in contacts: [String: String]) -> String? {
        handle.contains("@") ? contacts[handle.lowercased()] : contacts[key(handle)]
    }

    /// Phone number (last 10 digits) or lowercased email → contact name, from the backed-up address book.
    static func phoneNames(databaseAt url: URL) -> [String: String] {
        guard let db = try? SQLiteDB(path: url.path), db.tables().isSuperset(of: ["ABPerson", "ABMultiValue"]) else { return [:] }
        var out: [String: String] = [:]
        // property 3 = phone, 4 = email
        try? db.query("""
            SELECT p.First, p.Last, p.Organization, mv.value, mv.property FROM ABMultiValue mv
            JOIN ABPerson p ON p.ROWID = mv.record_id WHERE mv.property IN (3, 4) AND mv.value IS NOT NULL
            """) { r in
            guard let value = r.string(3) else { return }
            let name = [r.string(0), r.string(1)].compactMap { $0 }.joined(separator: " ")
            let display = name.isEmpty ? (r.string(2) ?? "") : name
            guard !display.isEmpty else { return }
            if r.int(4) == 4 { out[value.lowercased()] = display } else {
                let k = key(value)
                if k.count >= 6 { out[k] = display }
            }
        }
        return out
    }
}

// MARK: - Safari

struct SafariBookmark: Identifiable, Hashable {
    let id: Int
    let title: String
    let url: String?
    let isFolder: Bool
    var children: [SafariBookmark]?
}

struct SafariVisit: Identifiable, Hashable {
    let id: Int64
    let url: String
    let title: String?
    let date: Date?
    let visitCount: Int
    /// Synced through iCloud from another device (an iPhone, iPad or another Mac).
    var fromOtherDevice: Bool = false
    var host: String { URL(string: url)?.host ?? url }
}

enum SafariReader {
    static let bookmarksSource = (domain: "HomeDomain", path: "Library/Safari/Bookmarks.db")
    /// History moved between domains over iOS versions; try both. Encrypted backups only.
    static let historySources = [
        (domain: "AppDomain-com.apple.mobilesafari", path: "Library/Safari/History.db"),
        (domain: "HomeDomain", path: "Library/Safari/History.db"),
    ]

    /// Bookmark folders (Favorites, Reading List…) with their contents.
    static func bookmarks(databaseAt url: URL) throws -> [SafariBookmark] {
        let db = try SQLiteDB(path: url.path)
        let cols = db.columns("bookmarks")
        guard !cols.isEmpty else { return [] }
        func c(_ n: String) -> String { cols.contains(n) ? n : "NULL" }
        struct Row { let id: Int; let parent: Int?; let type: Int; let title: String?; let url: String?; let order: Int }
        var rows: [Row] = []
        try db.query("SELECT id, parent, type, title, url, \(c("order_index")), \(c("hidden")), \(c("deleted")) FROM bookmarks") { r in
            if (!r.isNull(6) && r.int(6) != 0) || (!r.isNull(7) && r.int(7) != 0) { return }
            rows.append(Row(id: r.int(0), parent: r.isNull(1) ? nil : r.int(1), type: r.int(2), title: r.string(3), url: r.string(4), order: r.isNull(5) ? 0 : r.int(5)))
        }
        let byParent = Dictionary(grouping: rows, by: { $0.parent ?? -1 })
        func build(_ row: Row, depth: Int) -> SafariBookmark {
            let kids = row.type == 1 && depth < 32 ? (byParent[row.id] ?? []).sorted { $0.order < $1.order }.map { build($0, depth: depth + 1) } : nil
            return SafariBookmark(id: row.id, title: folderTitle(row.title) ?? row.url ?? "Untitled", url: row.url, isFolder: row.type == 1, children: kids)
        }
        let rootIDs = Set(rows.filter { $0.parent == nil }.map(\.id))
        let top = rows.filter { $0.parent.map(rootIDs.contains) ?? false }.sorted { $0.order < $1.order }
        return top.map { build($0, depth: 0) }.filter { !$0.isFolder || !($0.children ?? []).isEmpty }
    }

    static func folderTitle(_ t: String?) -> String? {
        switch t {
        case "BookmarksBar": return "Favorites"
        case "BookmarksMenu": return "Bookmarks Menu"
        case "com.apple.ReadingList": return "Reading List"
        default: return t
        }
    }

    static func history(databaseAt url: URL, limit: Int = 20_000) throws -> [SafariVisit] {
        let db = try SQLiteDB(path: url.path)
        guard db.tables().isSuperset(of: ["history_items", "history_visits"]) else { return [] }
        // On a Mac, `origin` is 1 for visits synced from other devices.
        let origin = db.columns("history_visits").contains("origin") ? "v.origin" : "0"
        var out: [SafariVisit] = []
        try db.query("""
            SELECT v.id, i.url, v.title, v.visit_time, i.visit_count, \(origin) FROM history_visits v
            JOIN history_items i ON i.id = v.history_item ORDER BY v.visit_time DESC LIMIT ?
            """, [limit]) { r in
            guard let u = r.string(1) else { return }
            out.append(SafariVisit(id: r.int64(0), url: u, title: r.string(2), date: r.appleDate(3), visitCount: r.int(4), fromOtherDevice: r.int(5) == 1))
        }
        return out
    }

    static func historyCSV(_ visits: [SafariVisit]) -> String {
        let iso = ISO8601DateFormatter()
        var rows = ["Date,Title,URL,Visits"]
        for v in visits { rows.append([v.date.map { iso.string(from: $0) } ?? "", v.title ?? "", v.url, String(v.visitCount)].map(CSV.field).joined(separator: ",")) }
        return rows.joined(separator: "\n") + "\n"
    }

    static func bookmarksHTML(_ roots: [SafariBookmark]) -> String {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;") }
        func render(_ items: [SafariBookmark], _ indent: String) -> String {
            items.map { b in
                if b.isFolder {
                    return "\(indent)<DT><H3>\(esc(b.title))</H3>\n\(indent)<DL><p>\n\(render(b.children ?? [], indent + "    "))\(indent)</DL><p>\n"
                }
                return "\(indent)<DT><A HREF=\"\(esc(b.url ?? ""))\">\(esc(b.title))</A>\n"
            }.joined()
        }
        // Netscape bookmark format: Safari, Chrome and Firefox can import it.
        return "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n<TITLE>Bookmarks</TITLE>\n<H1>Bookmarks</H1>\n<DL><p>\n" + render(roots, "    ") + "</DL><p>\n"
    }
}

enum CSV {
    static func field(_ s: String) -> String {
        s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s
    }
}
