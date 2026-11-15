import Foundation

/// Full-text index over everything the session has loaded (messages, notes, calls, Safari).
/// It lives only in memory: nothing is written to disk, and it's gone when the session closes.
final class SearchIndex: @unchecked Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case message, note, call, visit, bookmark
    }

    struct Entry {
        var kind: Kind
        var service: MessagingService? = nil
        /// Identifies the item inside its section (message id, note id…).
        var ref: String
        var thread: String? = nil
        var title: String
        var body: String
        var date: Date? = nil
    }

    struct Hit: Identifiable, Hashable, Sendable {
        let id: Int64
        let kind: Kind
        let service: MessagingService?
        let ref: String
        let thread: String?
        let title: String
        /// Matching text with matches wrapped in U+0002 … U+0003.
        let snippet: String
        let date: Date?
    }

    struct Query: Equatable {
        var match: String = ""
        var services: Set<String> = []
        var kinds: Set<Kind> = []
        var after: Date?
        var before: Date?
        var isEmpty: Bool { match.isEmpty }
    }

    private let db: SQLiteDB
    private let lock = NSLock()

    init() throws {
        db = try SQLiteDB.inMemory()
        try db.execute("""
            CREATE VIRTUAL TABLE docs USING fts5(title, body, grp UNINDEXED, kind UNINDEXED, service UNINDEXED,
                ref UNINDEXED, thread UNINDEXED, date UNINDEXED, tokenize = 'unicode61 remove_diacritics 2')
            """)
    }

    /// Replaces everything indexed under `group` (one group per section, so a section can be
    /// re-indexed when its data changes).
    func replace(group: String, _ fill: ((Entry) -> Void) throws -> Void) rethrows {
        lock.lock(); defer { lock.unlock() }
        try? db.execute("BEGIN")
        try? db.query("DELETE FROM docs WHERE grp = ?", [group]) { _ in }
        defer { try? db.execute("COMMIT") }
        try fill { e in
            try? self.db.query("INSERT INTO docs (title, body, grp, kind, service, ref, thread, date) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                               [e.title, e.body, group, e.kind.rawValue, e.service?.rawValue, e.ref, e.thread, e.date?.timeIntervalSince1970]) { _ in }
        }
    }

    func remove(group: String) {
        lock.lock(); defer { lock.unlock() }
        try? db.query("DELETE FROM docs WHERE grp = ?", [group]) { _ in }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return Int(db.scalar("SELECT COUNT(*) FROM docs") ?? 0)
    }

    /// Turns what the user typed into a query. Words must all match (as prefixes); "quoted text"
    /// matches as a phrase; `from:alex`, `in:whatsapp` (or messages, instagram, notes, calls, safari),
    /// `before:2026-01-31` and `after:2025-12-01` narrow it down.
    static func parse(_ text: String) -> Query {
        var q = Query()
        var terms: [String] = []
        var rest = Substring(text)
        func quote(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: " ") + "\"" }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.locale = Locale(identifier: "en_US_POSIX")
        while let c = rest.first {
            if c.isWhitespace { rest = rest.dropFirst(); continue }
            if c == "\"" {
                let body = rest.dropFirst()
                let end = body.firstIndex(of: "\"") ?? body.endIndex
                let phrase = String(body[..<end]).trimmingCharacters(in: .whitespaces)
                if !phrase.isEmpty { terms.append(quote(phrase)) }
                rest = end < body.endIndex ? body[body.index(after: end)...] : ""
                continue
            }
            let end = rest.firstIndex(where: \.isWhitespace) ?? rest.endIndex
            let word = String(rest[..<end])
            rest = rest[end...]
            let lower = word.lowercased()
            if lower.hasPrefix("from:"), word.count > 5 {
                terms.append("title : " + quote(String(word.dropFirst(5))) + "*")
            } else if lower.hasPrefix("in:"), word.count > 3 {
                switch String(lower.dropFirst(3)) {
                case "whatsapp": q.services.insert(MessagingService.whatsapp.rawValue)
                case "messages", "imessage", "sms": q.services.insert(MessagingService.messages.rawValue)
                case "instagram": q.services.insert(MessagingService.instagram.rawValue)
                case "notes": q.kinds.insert(.note)
                case "calls": q.kinds.insert(.call)
                case "safari": q.kinds.formUnion([.visit, .bookmark])
                default: break
                }
            } else if lower.hasPrefix("before:"), let d = day.date(from: String(word.dropFirst(7))) {
                q.before = d
            } else if lower.hasPrefix("after:"), let d = day.date(from: String(word.dropFirst(6))) {
                q.after = d
            } else {
                let cleaned = word.trimmingCharacters(in: CharacterSet(charactersIn: "\"*:^(){}[]"))
                if !cleaned.isEmpty { terms.append(quote(cleaned) + "*") }
            }
        }
        q.match = terms.joined(separator: " ")
        return q
    }

    func search(_ text: String, limit: Int = 300) -> [Hit] {
        let q = Self.parse(text)
        guard !q.isEmpty else { return [] }
        var sql = """
            SELECT rowid, kind, service, ref, thread, title, snippet(docs, 1, char(2), char(3), '…', 16), date
            FROM docs WHERE docs MATCH ?
            """
        var bind: [Any?] = [q.match]
        var scope: [String] = []
        if !q.services.isEmpty {
            scope.append("service IN (" + q.services.map { _ in "?" }.joined(separator: ",") + ")")
            bind.append(contentsOf: q.services.sorted().map { $0 as Any? })
        }
        if !q.kinds.isEmpty {
            scope.append("kind IN (" + q.kinds.map { _ in "?" }.joined(separator: ",") + ")")
            bind.append(contentsOf: q.kinds.map(\.rawValue).sorted().map { $0 as Any? })
        }
        if !scope.isEmpty { sql += " AND (" + scope.joined(separator: " OR ") + ")" }
        if let a = q.after { sql += " AND CAST(date AS REAL) >= ?"; bind.append(a.timeIntervalSince1970) }
        if let b = q.before { sql += " AND CAST(date AS REAL) < ?"; bind.append(b.timeIntervalSince1970) }
        sql += " ORDER BY CAST(date AS REAL) DESC LIMIT \(max(1, limit))"

        lock.lock(); defer { lock.unlock() }
        var out: [Hit] = []
        try? db.query(sql, bind) { r in
            guard let kind = Kind(rawValue: r.string(1) ?? "") else { return }
            out.append(Hit(id: r.int64(0), kind: kind, service: r.string(2).flatMap(MessagingService.init(rawValue:)), ref: r.string(3) ?? "",
                           thread: r.string(4), title: r.string(5) ?? "", snippet: r.string(6) ?? "",
                           date: r.isNull(7) ? nil : Date(timeIntervalSince1970: r.double(7))))
        }
        return out
    }
}
