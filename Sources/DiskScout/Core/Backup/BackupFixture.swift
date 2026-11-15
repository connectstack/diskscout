#if DEBUG
import Foundation
import CryptoKit
import SQLite3

/// Builds sample iPhone backups (optionally encrypted, exactly like Finder's format) filled with
/// made-up WhatsApp chats, notes, calls, contacts and Safari data. Used by tests and for
/// screenshots, so no real person's data is ever needed to check the features.
enum BackupFixture {
    struct FileSpec { let domain: String; let path: String; let data: Data }

    static let sampleUDID = "00000000-0000000000SAMPLE"

    @discardableResult
    static func make(in root: URL, udid: String = sampleUDID, deviceName: String = "Sample iPhone",
                     password: String? = nil, rounds: (dpic: Int, iter: Int) = (1_000, 100)) throws -> IOSBackupInfo {
        let dir = root.appendingPathComponent(udid, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let files = try sampleFiles(scratch: scratch)

        // Keys (encrypted backups only).
        var classKeys: [Int: Data] = [:]
        var keybag = Data()
        var manifestKeyBlob: Data?
        var manifestKey: Data?
        if let password {
            let salt = random(20), dpsl = random(20)
            let secret = BackupAES.pbkdf2(BackupAES.pbkdf2(Data(password.utf8), salt: dpsl, rounds: rounds.dpic, sha256: true)!,
                                          salt: salt, rounds: rounds.iter, sha256: false)!
            keybag += tlv("VERS", int: 3) + tlv("TYPE", int: 1) + tlv("UUID", random(16)) + tlv("HMCK", Data(count: 40))
            keybag += tlv("WRAP", int: 0) + tlv("SALT", salt) + tlv("ITER", int: rounds.iter) + tlv("DPWT", int: 1)
            keybag += tlv("DPIC", int: rounds.dpic) + tlv("DPSL", dpsl)
            for clas in 1...4 {
                let key = random(32)
                classKeys[clas] = key
                keybag += tlv("UUID", random(16)) + tlv("CLAS", int: clas) + tlv("WRAP", int: 2) + tlv("KTYP", int: 0)
                keybag += tlv("WPKY", BackupAES.wrap(kek: secret, key: key)!)
            }
            let mk = random(32)
            manifestKey = mk
            manifestKeyBlob = le32(4) + BackupAES.wrap(kek: classKeys[4]!, key: mk)!
        }

        // Manifest.db and payloads.
        let manifestPath = scratch.appendingPathComponent("Manifest.db").path
        var db: OpaquePointer?
        guard sqlite3_open(manifestPath, &db) == SQLITE_OK else { throw SQLiteDB.Failure.open("fixture manifest") }
        sqlite3_exec(db, "CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB); CREATE TABLE Properties (key TEXT PRIMARY KEY, value BLOB);", nil, nil, nil)
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO Files VALUES (?, ?, ?, 1, ?)", -1, &stmt, nil)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for f in files {
            let id = Insecure.SHA1.hash(data: Data("\(f.domain)-\(f.path)".utf8)).map { String(format: "%02x", $0) }.joined()
            let folder = dir.appendingPathComponent(String(id.prefix(2)), isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let record = BackupFileRecord(size: Int64(f.data.count), protectionClass: 3, encryptionKey: nil, lastModified: Int64(Date().timeIntervalSince1970))
            if password != nil {
                let fileKey = random(32)
                record.encryptionKey = le32(3) + BackupAES.wrap(kek: classKeys[3]!, key: fileKey)!
                try BackupAES.crypt(pad(f.data), key: fileKey, encrypt: true).write(to: folder.appendingPathComponent(id))
            } else {
                try f.data.write(to: folder.appendingPathComponent(id))
            }
            let blob = try record.archived()
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, id, -1, transient)
            sqlite3_bind_text(stmt, 2, f.domain, -1, transient)
            sqlite3_bind_text(stmt, 3, f.path, -1, transient)
            _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 4, $0.baseAddress, Int32(blob.count), transient) }
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        sqlite3_close(db)
        let manifestData = try Data(contentsOf: URL(fileURLWithPath: manifestPath))
        if let manifestKey {
            try BackupAES.crypt(pad(manifestData), key: manifestKey, encrypt: true).write(to: dir.appendingPathComponent("Manifest.db"))
        } else {
            try manifestData.write(to: dir.appendingPathComponent("Manifest.db"))
        }

        // Plists.
        let date = Date()
        let lockdown: [String: Any] = ["DeviceName": deviceName, "ProductType": "iPhone14,2", "ProductVersion": "26.3", "UniqueDeviceID": udid]
        var manifest: [String: Any] = ["IsEncrypted": password != nil, "Lockdown": lockdown, "Date": date, "Version": "10.0"]
        if password != nil { manifest["BackupKeyBag"] = keybag; manifest["ManifestKey"] = manifestKeyBlob }
        try write(manifest, to: dir.appendingPathComponent("Manifest.plist"))
        try write(["Device Name": deviceName, "Display Name": deviceName, "Last Backup Date": date, "Product Type": "iPhone14,2",
                   "Product Version": "26.3", "Target Identifier": udid, "Unique Identifier": udid], to: dir.appendingPathComponent("Info.plist"))
        try write(["SnapshotState": "finished", "Date": date, "IsFullBackup": false], to: dir.appendingPathComponent("Status.plist"))
        return IOSBackupInfo.read(at: dir)!
    }

    /// A sample home folder laid out like a Mac with WhatsApp for Mac, iCloud Notes, call history,
    /// Contacts and Safari. Same invented content as the sample backup.
    static func makeMacHome(in root: URL) throws {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let files = try sampleFiles(scratch: scratch)
        func data(_ domain: String, _ path: String) -> Data { files.first { $0.domain == domain && $0.path == path }!.data }
        func put(_ d: Data, _ relative: String) throws {
            let url = root.appendingPathComponent(relative)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try d.write(to: url)
        }
        let wa = WhatsAppReader.sources[0].domain
        let container = MacSyncedData.whatsappContainers[0].0
        try put(data(wa, WhatsAppReader.databasePath), container + "/ChatStorage.sqlite")
        try put(data(wa, "Message/Media/120363000000000001@g.us/a/b/photo1.jpg"), container + "/Message/Media/120363000000000001@g.us/a/b/photo1.jpg")
        try put(data(NotesReader.domain, NotesReader.databasePath), MacSyncedData.notesPath)
        try put(data(CallHistoryReader.domain, CallHistoryReader.databasePath), MacSyncedData.callsPath)
        try put(database(scratch, "AddressBook-v22.abcddb", """
            CREATE TABLE ZABCDRECORD (Z_PK INTEGER PRIMARY KEY, ZFIRSTNAME TEXT, ZLASTNAME TEXT, ZORGANIZATION TEXT);
            CREATE TABLE ZABCDPHONENUMBER (Z_PK INTEGER PRIMARY KEY, ZOWNER INTEGER, ZFULLNUMBER TEXT);
            INSERT INTO ZABCDRECORD VALUES (1, 'Alex', 'Morgan', NULL), (2, 'Sam', 'Lee', NULL);
            INSERT INTO ZABCDPHONENUMBER VALUES (1, 1, '+1 (555) 010-0001'), (2, 2, '+1 555 010 0002');
            """), MacSyncedData.contactsDir + "/Sources/SAMPLE-SOURCE/AddressBook-v22.abcddb")
        try put(try messagesDatabase(scratch, attachmentsRoot: "~/Library/Messages/Attachments"), MessagesStore.macDatabasePath)
        try put(Data(repeating: 0xCD, count: 2048), "Library/Messages/Attachments/aa/01/IMG_0042.heic")
        let bookmarks: [String: Any] = ["WebBookmarkType": "WebBookmarkTypeList", "Title": "", "Children": [
            ["WebBookmarkType": "WebBookmarkTypeProxy", "Title": "History"],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "BookmarksBar", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://www.apple.com/", "URIDictionary": ["title": "Apple"]],
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://en.wikipedia.org/", "URIDictionary": ["title": "Wikipedia"]],
            ]],
            ["WebBookmarkType": "WebBookmarkTypeList", "Title": "com.apple.ReadingList", "Children": [
                ["WebBookmarkType": "WebBookmarkTypeLeaf", "URLString": "https://example.com/trails", "URIDictionary": ["title": "Hiking trails near me"]],
            ]],
        ]]
        try put(PropertyListSerialization.data(fromPropertyList: bookmarks, format: .binary, options: 0), MacSyncedData.bookmarksPath)
        let base = Date().timeIntervalSinceReferenceDate
        try put(database(scratch, "History.db", """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, domain_expansion TEXT, visit_count INTEGER);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT, origin INTEGER NOT NULL DEFAULT 0);
            INSERT INTO history_items VALUES (1, 'https://www.apple.com/iphone/', 'apple', 3), (2, 'https://en.wikipedia.org/wiki/Lisbon', 'wikipedia', 1), (3, 'https://example.com/trails', NULL, 2);
            INSERT INTO history_visits VALUES (1, 1, \(base - 7200), 'iPhone - Apple', 1), (2, 2, \(base - 108000), 'Lisbon - Wikipedia', 0), (3, 3, \(base - 14400), 'Trails', 1);
            """), MacSyncedData.historyPath)
    }

    /// A Messages database (chat.db / sms.db). One message keeps its text only in `attributedBody`,
    /// the way current macOS and iOS store it.
    static func messagesDatabase(_ scratch: URL, attachmentsRoot: String) throws -> Data {
        let base = Date().timeIntervalSinceReferenceDate
        func ns(_ hoursAgo: Double) -> Int64 { Int64((base - hoursAgo * 3600) * 1_000_000_000) }
        let body = "X'" + attributedBody("Running ten minutes late, sorry!").map { String(format: "%02X", $0) }.joined() + "'"
        return try database(scratch, "chat.db", """
            CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, style INTEGER, chat_identifier TEXT, service_name TEXT, display_name TEXT);
            CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT, service TEXT);
            CREATE TABLE message (ROWID INTEGER PRIMARY KEY, guid TEXT, text TEXT, attributedBody BLOB, handle_id INTEGER, date INTEGER, is_from_me INTEGER,
                item_type INTEGER DEFAULT 0, associated_message_type INTEGER DEFAULT 0, cache_has_attachments INTEGER DEFAULT 0, group_title TEXT);
            CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER, message_date INTEGER);
            CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER);
            CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, filename TEXT, mime_type TEXT, transfer_name TEXT, total_bytes INTEGER);
            CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER);
            INSERT INTO handle VALUES (1, '+15550100001', 'iMessage'), (2, '+15550100002', 'SMS'), (3, 'priya@example.com', 'iMessage');
            INSERT INTO chat VALUES (1, 'iMessage;-;+15550100001', 45, '+15550100001', 'iMessage', NULL);
            INSERT INTO chat VALUES (2, 'SMS;-;+15550100001', 45, '+15550100001', 'SMS', NULL);
            INSERT INTO chat VALUES (3, 'iMessage;+;chat123', 43, 'chat123', 'iMessage', 'Book Club');
            INSERT INTO chat VALUES (4, 'iMessage;+;chat456', 43, 'chat456', 'iMessage', NULL);
            INSERT INTO chat_handle_join VALUES (3, 1), (3, 3), (4, 2), (4, 3);
            INSERT INTO message VALUES (1, 'm1', 'Lunch on Thursday?', NULL, 1, \(ns(30)), 0, 0, 0, 0, NULL);
            INSERT INTO message VALUES (2, 'm2', 'Yes! 12:30 at the usual place', NULL, 1, \(ns(29)), 1, 0, 0, 0, NULL);
            INSERT INTO message VALUES (3, 'm3', NULL, \(body), 1, \(ns(2)), 0, 0, 0, 0, NULL);
            INSERT INTO message VALUES (4, 'm4', 'Liked “Running ten minutes late, sorry!”', NULL, 1, \(ns(1.9)), 1, 0, 2001, 0, NULL);
            INSERT INTO message VALUES (5, 'm5', 'Your code is 482913', NULL, 1, \(ns(100)), 0, 0, 0, 0, NULL);
            INSERT INTO message VALUES (6, 'm6', 'Chapter 4 by Friday everyone', NULL, 3, \(ns(5)), 0, 0, 0, 0, NULL);
            INSERT INTO message VALUES (7, 'm7', '\u{FFFC}', NULL, 3, \(ns(4)), 0, 0, 0, 1, NULL);
            INSERT INTO message VALUES (8, 'm8', NULL, NULL, 0, \(ns(50)), 0, 2, 0, 0, 'Book Club');
            INSERT INTO message VALUES (9, 'm9', 'Dinner at 8?', NULL, 2, \(ns(70)), 0, 0, 0, 0, NULL);
            INSERT INTO chat_message_join VALUES (1, 1, \(ns(30))), (1, 2, \(ns(29))), (1, 3, \(ns(2))), (1, 4, \(ns(1.9))), (2, 5, \(ns(100))),
                (3, 6, \(ns(5))), (3, 7, \(ns(4))), (3, 8, \(ns(50))), (4, 9, \(ns(70)));
            INSERT INTO attachment VALUES (1, '\(attachmentsRoot)/aa/01/IMG_0042.heic', 'image/heic', 'IMG_0042.heic', 2048);
            INSERT INTO message_attachment_join VALUES (7, 1);
            """)
    }

    /// The shape of a real `attributedBody` around its text: the NSString class marker, a `+`, a
    /// length, then UTF-8. (Tests also check the reader against a genuine archive.)
    static func attributedBody(_ text: String) -> Data {
        let utf8 = Array(text.utf8)
        var d = Data([0x04, 0x0B]) + Data("streamtyped".utf8) + Data([0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84, 0x12])
        d += Data("NSAttributedString".utf8) + Data([0x00, 0x84, 0x84, 0x08]) + Data("NSObject".utf8) + Data([0x00, 0x85, 0x92, 0x84, 0x84, 0x84, 0x08])
        d += Data("NSString".utf8) + Data([0x01, 0x94, 0x84, 0x01, 0x2B])
        if utf8.count < 0x80 { d.append(UInt8(utf8.count)) } else { d += Data([0x81, UInt8(utf8.count & 0xFF), UInt8(utf8.count >> 8)]) }
        return d + Data(utf8) + Data([0x86, 0x84, 0x02, 0x69, 0x49, 0x01, 0x20])
    }

    /// A folder shaped like Meta's "Download your information" export (JSON), with its mis-encoded text.
    static func makeInstagramExport(in root: URL) throws {
        let fm = FileManager.default
        let now = Date().timeIntervalSince1970 * 1000
        func mangle(_ s: String) -> String { String(data: Data(s.utf8), encoding: .isoLatin1) ?? s }
        func write(_ thread: String, _ json: [String: Any]) throws {
            let dir = root.appendingPathComponent("your_instagram_activity/messages/inbox/\(thread)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("message_1.json"))
        }
        let me = "Jamie Rivera"
        let photo = "your_instagram_activity/messages/inbox/noor_1001/photos/sunset.jpg"
        try fm.createDirectory(at: root.appendingPathComponent(photo).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0xEE, count: 3000).write(to: root.appendingPathComponent(photo))
        try write("noor_1001", ["participants": [["name": "Noor Haddad"], ["name": me]], "title": "Noor Haddad", "messages": [
            ["sender_name": me, "timestamp_ms": now - 3_600_000, "content": mangle("That café was great ☕️")],
            ["sender_name": "Noor Haddad", "timestamp_ms": now - 7_200_000, "photos": [["uri": photo, "creation_timestamp": Int(now / 1000)]]],
            ["sender_name": "Noor Haddad", "timestamp_ms": now - 9_000_000, "content": "Look at this", "share": ["link": "https://www.instagram.com/p/EXAMPLE/"]],
        ]])
        try write("climbers_1002", ["participants": [["name": "Noor Haddad"], ["name": "Leo Tanaka"], ["name": me]], "title": "Climbing crew", "messages": [
            ["sender_name": "Leo Tanaka", "timestamp_ms": now - 90_000_000, "content": "Gym at 7?"],
            ["sender_name": me, "timestamp_ms": now - 89_000_000, "content": "In."],
        ]])
    }

    /// The same kind of conversations the way Instagram's default HTML export writes them: one
    /// page per thread, newest message first, times in US Pacific. All invented.
    static func makeInstagramHTMLExport(in root: URL) throws {
        let fm = FileManager.default
        let inbox = "your_instagram_activity/messages/inbox"
        let box = "pam _3-95 _2ph- _a6-g uiBoxWhite noborder"
        func page(_ title: String, _ blocks: [String], base: String = "../../../../") -> String {
            """
            <html><head><meta http-equiv="Content-Type" content="text/html; charset=UTF-8"><base href="\(base)"><style type="text/css">._a6-g { padding: 0 } div > h2 { color: #000 }</style><title>\(title)</title></head>
            <body class="_5vb_ _2yq _a7o5"><div class="_li"><div class="_as_0"><img src="files/Instagram-Logo.png" height="32" alt="" /></div><div class="_a705"><header class="_as-_ _a70a" aria-labelledby="u1"><div class="_a70d"><h1 id="u1">\(title)</h1><aside role="contentinfo" class="_aoaa">Generated by jamie.rivera on <time datetime="2026-11-13T13:05Z">Friday 13 November 2026 at 13:05 UTC</time></aside></div></header>
            <main class="_a706" role="main">\(blocks.joined())</main></div></div></body></html>
            """
        }
        func message(_ sender: String, _ text: String, _ date: String, share: String = "", extra: String = "") -> String {
            "<div class=\"\(box)\"><h2 class=\"_3-95 _2pim _a6-h _a6-i\">\(sender)</h2><div class=\"_3-95 _a6-p\"><div><div></div><div>\(text)</div><div>\(share)</div><div></div>\(extra)</div></div><div class=\"_3-94 _a6-o\">\(date)</div></div>"
        }
        func write(_ thread: String, _ html: String) throws {
            let dir = root.appendingPathComponent("\(inbox)/\(thread)", isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(html.utf8).write(to: dir.appendingPathComponent("message_1.html"))
        }
        func file(_ path: String, bytes: Int) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 0xEE, count: bytes).write(to: url)
        }
        let photo = "\(inbox)/noor_1001/photos/sunset.jpg"
        let clip = "\(inbox)/climbers_1002/videos/clip.mp4"
        try file(photo, bytes: 3000)
        try file(clip, bytes: 5000)
        // Something an export is full of and DiskScout never needs.
        try file("media/posts/202611/holiday.jpg", bytes: 20_000)

        try write("noor_1001", page("Noor Haddad", [
            message("Jamie Rivera", "That caf&#233; was great ☕️ &amp; cheap<br />Same time next week?", "Nov 12, 2026 3:45 pm",
                    extra: "<div><ul class=\"_a6-q\"><li><span>❤Noor Haddad (Nov 12, 2026 3:46 pm)</span></li></ul></div>"),
            message("Noor Haddad", "", "Nov 12, 2026 3:40 pm",
                    extra: "<div><a target=\"_blank\" href=\"\(photo)\"><img src=\"\(photo)\" class=\"_a6_o _3-96\" /></a><div></div></div>"),
            message("Noor Haddad", "Noor Haddad sent an attachment.", "Nov 12, 2026 3:40 pm",
                    share: "<a target=\"_blank\" href=\"https://www.instagram.com/p/EXAMPLE/\">https://www.instagram.com/p/EXAMPLE/</a><div>Look at this</div>"),
            message("Noor Haddad", "Noor Haddad started an audio call", "Jul 04, 2026 12:05 am",
                    extra: "<div><span class=\"_idm\">Duration: 12 seconds</span></div>"),
        ]))
        try write("climbers_1002", page("Climbing crew", [
            "<div class=\"\(box)\"><h2 class=\"_a6-h\">Participants: Noor Haddad, Leo Tanaka, Jamie Rivera</h2></div>",
            "<div class=\"\(box)\"><h2 class=\"_3-95 _2pim _a6-h _a6-i\">Group invitation link: On</h2><div class=\"_3-95 _a6-p\">https://ig.me/j/EXAMPLE</div></div>",
            message("Leo Tanaka", "", "Nov 10, 2026 9:02 am",
                    extra: "<div><video src=\"\(clip)\" controls=\"1\" class=\"_a6_o _3-96\"><a target=\"_blank\" href=\"\(clip)\">Click for video:</a></video></div>"),
            message("Jamie Rivera", "In.", "Nov 10, 2026 9:01 am"),
            message("Leo Tanaka", "Gym at 7? 1 &lt; 2", "Nov 10, 2026 9:00 am"),
        ]))

        // The rest of an export: the same boxes, holding tables of labels and values.
        func other(_ path: String, _ title: String, _ blocks: [String]) throws {
            let url = root.appendingPathComponent(path)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let depth = path.split(separator: "/").count - 1
            try Data(page(title, blocks, base: String(repeating: "../", count: depth)).utf8).write(to: url)
        }
        func nested(_ label: String, _ value: String) -> String { "<tr><td colspan=\"2\" class=\"_2pin _a6_q\">\(label)<div><div>\(value)</div></div></td></tr>" }
        func pair(_ label: String, _ value: String) -> String { "<tr><td class=\"_2pin _a6_q\">\(label)</td><td class=\"_2pin _2piu _a6_r\">\(value)</td></tr>" }
        func table(_ rows: [String]) -> String { "<table style=\"table-layout: fixed;\">\(rows.joined())</table>" }
        func record(_ inner: String, date: String = "") -> String {
            "<div class=\"\(box)\"><div class=\"_a6-p\"><div><div>\(inner)</div></div></div><div class=\"_3-94 _a6-o\">\(date)</div></div>"
        }
        func section(_ heading: String, _ inner: String) -> String {
            "<tr><td colspan=\"2\"><div><div><h2 class=\"_a6-h\">\(heading)</h2><div><div><div>\(inner)</div></div></div></div></div></td></tr>"
        }

        try other("start_here.html", "Your Instagram information", ["<div><div><header><h3>Messages</h3><p>Your conversations</p></header><nav><div><a href=\"your_instagram_activity/messages/chats.html\">Chats</a></div></nav></div></div>"])
        try other("your_instagram_activity/messages/chats.html", "Chats", ["<div class=\"\(box)\"><h2 class=\"_a6-h\"><a href=\"\(inbox)/noor_1001/message_1.html\">Noor Haddad</a></h2></div>"])

        try other("connections/followers_and_following/following.html", "Following", [("noor.h", "Nov 12, 2026 3:45 pm"), ("leo.climbs", "Oct 01, 2026 8:00 am"), ("trail.mix", "Jan 05, 2025 11:30 pm")].map { name, date in
            "<div class=\"\(box)\"><h2 class=\"_3-95 _2pim _a6-h _a6-i\">\(name)</h2><div class=\"_a6-p\"><div><div><a target=\"_blank\" href=\"https://www.instagram.com/_u/\(name)\">https://www.instagram.com/_u/\(name)</a></div><div>\(date)</div></div></div></div>"
        })

        try other("connections/contacts/synced_contacts.html", "Synced contacts", [("Alex", "Morgan", "+1 555 010 0001"), ("Sam", "Lee", "sam@example.com"), ("Priya", "Shah", "+1 555 010 0003")].map { first, last, contact in
            "<div class=\"\(box)\"><div class=\"_a6-p\">" + table([nested("First Name", first), nested("Last Name", last), nested("Contact Information", contact)]) + "</div></div>"
        })

        try other("security_and_login_information/login_and_profile_creation/login_activity.html", "Login activity", [("2026-11-10T17:00:00+00:00", "203.0.113.7", "Nov 10, 2026 9:00 am"), ("2026-10-02T04:30:00+00:00", "198.51.100.23", "Oct 01, 2026 9:30 pm")].map { stamp, ip, time in
            "<div class=\"\(box)\"><h2 class=\"_3-95 _2pim _a6-h _a6-i\">\(stamp)</h2><div class=\"_a6-p\">"
                + table([nested("Cookie Name", "*************************abc"), nested("IP Address", ip), pair("Time", time), nested("User Agent", "Instagram 400.0 (iPhone14,2; iOS 26_3)")])
                + "</div></div>"
        })

        let advertisers = (1...15).map { "<div><div><div>Example Advertiser \($0)</div></div></div>" }.joined()
        try other("ads_information/instagram_ads_and_businesses/advertisers_using_your_activity_or_information.html", "Advertisers using your activity or information", [
            record(table(["<tr><td colspan=\"2\" class=\"_2pin _a6_q\">Advertisers using your activity or information<div><div>\(advertisers)</div></div></td></tr>"])),
        ])

        let owner = { (username: String, name: String) in section("Owner", table(["<tr><td><div><div><div><div><div>" + table([pair("URL", "<a target=\"_blank\" href=\"https://www.instagram.com/\(username)\">https://www.instagram.com/\(username)</a>"), pair("Name", name), pair("Username", username)]) + "</div></div></div></div></div></td></tr>"])) }
        let hashtags = section("Hashtags", "Hashtags" + (1...14).map { "<div><div><div><div>#tag\($0)</div></div></div></div>" }.joined())
        try other("your_instagram_activity/likes/liked_posts.html", "Liked posts", (1...5).map { i in
            record(table([
                "<tr><td colspan=\"2\" class=\"_2pin _a6_q\">URL<div><a target=\"_blank\" href=\"https://www.instagram.com/p/POST\(i)/\">https://www.instagram.com/p/POST\(i)/</a></div></td></tr>",
                pair("Caption", "Morning light, take \(i)"),
                owner("noor.h", "Noor Haddad"),
                i == 2 ? hashtags : "",
            ]), date: "Nov 0\(i), 2026 7:15 am")
        })

        let post = "media/posts/202611/holiday.jpg"
        try other("your_instagram_activity/media/posts.html", "Posts", [
            record(table([pair("Title", "Weekend in the hills"), "<tr><td>Media</td><td><div><a target=\"_blank\" href=\"\(post)\"><img src=\"\(post)\" class=\"_a6_o _3-96\" /></a><div></div></div></td></tr>", pair("Creation Timestamp", "Nov 02, 2026 6:00 pm")]), date: "Nov 02, 2026 6:00 pm"),
        ])
    }

    // MARK: Sample content (all invented)

    static func sampleFiles(scratch: URL) throws -> [FileSpec] {
        let base = Date().timeIntervalSinceReferenceDate
        func t(_ hoursAgo: Double) -> Double { base - hoursAgo * 3600 }

        let whatsapp = try database(scratch, "ChatStorage.sqlite", """
            CREATE TABLE ZWACHATSESSION (Z_PK INTEGER PRIMARY KEY, ZPARTNERNAME TEXT, ZCONTACTJID TEXT, ZLASTMESSAGEDATE REAL, ZSESSIONTYPE INTEGER, ZARCHIVED INTEGER, ZREMOVED INTEGER);
            CREATE TABLE ZWAGROUPMEMBER (Z_PK INTEGER PRIMARY KEY, ZMEMBERJID TEXT, ZCONTACTNAME TEXT);
            CREATE TABLE ZWAMESSAGE (Z_PK INTEGER PRIMARY KEY, ZCHATSESSION INTEGER, ZISFROMME INTEGER, ZMESSAGEDATE REAL, ZTEXT TEXT, ZMESSAGETYPE INTEGER, ZFROMJID TEXT, ZGROUPMEMBER INTEGER, ZMEDIAITEM INTEGER);
            CREATE TABLE ZWAMEDIAITEM (Z_PK INTEGER PRIMARY KEY, ZMESSAGE INTEGER, ZMEDIALOCALPATH TEXT, ZFILESIZE INTEGER, ZTITLE TEXT);
            INSERT INTO ZWACHATSESSION VALUES (1, 'Weekend Hikers', '120363000000000001@g.us', \(t(1)), 1, 0, 0);
            INSERT INTO ZWACHATSESSION VALUES (2, 'Alex Morgan', '15550100001@s.whatsapp.net', \(t(3)), 0, 0, 0);
            INSERT INTO ZWACHATSESSION VALUES (3, 'Sam Lee', '15550100002@s.whatsapp.net', \(t(30)), 0, 0, 0);
            INSERT INTO ZWACHATSESSION VALUES (4, NULL, 'status@broadcast', \(t(2)), 0, 0, 0);
            INSERT INTO ZWAGROUPMEMBER VALUES (1, '15550100001@s.whatsapp.net', 'Alex Morgan'), (2, '15550100003@s.whatsapp.net', 'Priya Shah');
            INSERT INTO ZWAMESSAGE VALUES (1, 1, 0, \(t(5)), 'Who is in for Saturday?', 0, NULL, 2, NULL);
            INSERT INTO ZWAMESSAGE VALUES (2, 1, 1, \(t(4.5)), 'Count me in!', 0, NULL, NULL, NULL);
            INSERT INTO ZWAMESSAGE VALUES (3, 1, 0, \(t(4)), NULL, 1, NULL, 1, 1);
            INSERT INTO ZWAMESSAGE VALUES (4, 1, 0, \(t(1)), 'Trail map from last time', 2, NULL, 2, 2);
            INSERT INTO ZWAMESSAGE VALUES (5, 2, 0, \(t(6)), 'Did the parcel arrive?', 0, '15550100001@s.whatsapp.net', NULL, NULL);
            INSERT INTO ZWAMESSAGE VALUES (6, 2, 1, \(t(3)), 'Yes, thanks!', 0, NULL, NULL, NULL);
            INSERT INTO ZWAMESSAGE VALUES (7, 3, 1, \(t(30)), NULL, 3, NULL, NULL, 3);
            INSERT INTO ZWAMESSAGE VALUES (8, 4, 0, \(t(2)), 'status update', 1, NULL, NULL, NULL);
            INSERT INTO ZWAMEDIAITEM VALUES (1, 3, 'Media/120363000000000001@g.us/a/b/photo1.jpg', 2400000, NULL);
            INSERT INTO ZWAMEDIAITEM VALUES (2, 4, 'Media/120363000000000001@g.us/c/d/trail.mp4', 48000000, 'trail.mp4');
            INSERT INTO ZWAMEDIAITEM VALUES (3, 7, 'Media/15550100002@s.whatsapp.net/e/f/voice.opus', 180000, NULL);
            """)

        func note(_ text: String) -> String {
            let proto = field(2, field(3, field(2, Data(text.utf8))))
            return "X'" + gzip(proto).map { String(format: "%02X", $0) }.joined() + "'"
        }
        let notes = try database(scratch, "NoteStore.sqlite", """
            CREATE TABLE ZICCLOUDSYNCINGOBJECT (Z_PK INTEGER PRIMARY KEY, ZTITLE1 TEXT, ZTITLE2 TEXT, ZSNIPPET TEXT, ZFOLDER INTEGER, ZFOLDERTYPE INTEGER,
                ZCREATIONDATE3 REAL, ZMODIFICATIONDATE1 REAL, ZISPASSWORDPROTECTED INTEGER, ZISPINNED INTEGER, ZMARKEDFORDELETION INTEGER, ZNOTEDATA INTEGER);
            CREATE TABLE ZICNOTEDATA (Z_PK INTEGER PRIMARY KEY, ZNOTE INTEGER, ZDATA BLOB);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (1, NULL, 'Notes', NULL, NULL, 0, NULL, NULL, 0, 0, 0, NULL);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (2, NULL, 'Recently Deleted', NULL, NULL, 1, NULL, NULL, 0, 0, 0, NULL);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (10, 'Grocery list', NULL, 'Oat milk, apples…', 1, NULL, \(t(200)), \(t(2)), 0, 1, 0, 100);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (11, 'Trip ideas', NULL, 'Lisbon in spring', 1, NULL, \(t(900)), \(t(48)), 0, 0, 0, 101);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (12, 'Private', NULL, NULL, 1, NULL, \(t(800)), \(t(400)), 1, 0, 0, 102);
            INSERT INTO ZICCLOUDSYNCINGOBJECT VALUES (13, 'Old draft', NULL, 'Never sent', 2, NULL, \(t(2000)), \(t(100)), 0, 0, 0, 103);
            INSERT INTO ZICNOTEDATA VALUES (100, 10, \(note("Grocery list\nOat milk, apples, coffee beans\n\u{FFFC}\nRemember the receipt")));
            INSERT INTO ZICNOTEDATA VALUES (101, 11, \(note("Trip ideas\nLisbon in spring\nTram 28, Belém, a day in Sintra")));
            INSERT INTO ZICNOTEDATA VALUES (102, 12, X'00');
            INSERT INTO ZICNOTEDATA VALUES (103, 13, \(note("Old draft\nNever sent")));
            """)

        let calls = try database(scratch, "CallHistory.storedata", """
            CREATE TABLE ZCALLRECORD (Z_PK INTEGER PRIMARY KEY, ZDATE REAL, ZDURATION REAL, ZORIGINATED INTEGER, ZANSWERED INTEGER, ZCALLTYPE INTEGER,
                ZSERVICE_PROVIDER TEXT, ZADDRESS TEXT, ZNAME TEXT, ZLOCATION TEXT);
            INSERT INTO ZCALLRECORD VALUES (1, \(t(1)), 312, 1, 1, 1, 'com.apple.Telephony', '+1 555-010-0001', NULL, 'California');
            INSERT INTO ZCALLRECORD VALUES (2, \(t(5)), 0, 0, 0, 1, 'com.apple.Telephony', '+15550100002', NULL, NULL);
            INSERT INTO ZCALLRECORD VALUES (3, \(t(20)), 1260, 0, 1, 8, 'com.apple.FaceTime', 'priya@example.com', NULL, NULL);
            INSERT INTO ZCALLRECORD VALUES (4, \(t(26)), 95, 1, 1, 1, 'net.whatsapp.WhatsApp', '15550100003@s.whatsapp.net', 'Priya Shah', NULL);
            INSERT INTO ZCALLRECORD VALUES (5, \(t(50)), 0, 0, 0, 1, 'com.apple.Telephony', '+15550109999', NULL, 'New York');
            """)

        let contacts = try database(scratch, "AddressBook.sqlitedb", """
            CREATE TABLE ABPerson (ROWID INTEGER PRIMARY KEY, First TEXT, Last TEXT, Organization TEXT);
            CREATE TABLE ABMultiValue (UID INTEGER PRIMARY KEY, record_id INTEGER, property INTEGER, value TEXT);
            INSERT INTO ABPerson VALUES (1, 'Alex', 'Morgan', NULL), (2, 'Sam', 'Lee', NULL);
            INSERT INTO ABMultiValue VALUES (1, 1, 3, '(555) 010-0001'), (2, 2, 3, '555 010 0002');
            """)

        let bookmarks = try database(scratch, "Bookmarks.db", """
            CREATE TABLE bookmarks (id INTEGER PRIMARY KEY, special_id INTEGER, parent INTEGER, type INTEGER, title TEXT, url TEXT, num_children INTEGER, hidden INTEGER, order_index INTEGER, deleted INTEGER);
            INSERT INTO bookmarks VALUES (0, 0, NULL, 1, 'Root', NULL, 3, 0, 0, 0);
            INSERT INTO bookmarks VALUES (1, 1, 0, 1, 'BookmarksBar', NULL, 2, 0, 0, 0);
            INSERT INTO bookmarks VALUES (2, 0, 0, 1, 'com.apple.ReadingList', NULL, 1, 0, 1, 0);
            INSERT INTO bookmarks VALUES (3, 0, 1, 0, 'Apple', 'https://www.apple.com/', 0, 0, 0, 0);
            INSERT INTO bookmarks VALUES (4, 0, 1, 0, 'Wikipedia', 'https://en.wikipedia.org/', 0, 0, 1, 0);
            INSERT INTO bookmarks VALUES (5, 0, 2, 0, 'Hiking trails near me', 'https://example.com/trails', 0, 0, 0, 0);
            """)

        let history = try database(scratch, "History.db", """
            CREATE TABLE history_items (id INTEGER PRIMARY KEY, url TEXT, domain_expansion TEXT, visit_count INTEGER);
            CREATE TABLE history_visits (id INTEGER PRIMARY KEY, history_item INTEGER, visit_time REAL, title TEXT);
            INSERT INTO history_items VALUES (1, 'https://www.apple.com/iphone/', 'apple', 3), (2, 'https://en.wikipedia.org/wiki/Lisbon', 'wikipedia', 1), (3, 'https://example.com/trails', NULL, 2);
            INSERT INTO history_visits VALUES (1, 1, \(t(2)), 'iPhone - Apple'), (2, 2, \(t(30)), 'Lisbon - Wikipedia'), (3, 3, \(t(4)), 'Trails'), (4, 1, \(t(60)), 'iPhone - Apple');
            """)

        return [
            FileSpec(domain: WhatsAppReader.sources[0].domain, path: WhatsAppReader.databasePath, data: whatsapp),
            FileSpec(domain: WhatsAppReader.sources[0].domain, path: "Message/Media/120363000000000001@g.us/a/b/photo1.jpg", data: Data(repeating: 0xAB, count: 4096)),
            FileSpec(domain: NotesReader.domain, path: NotesReader.databasePath, data: notes),
            FileSpec(domain: CallHistoryReader.domain, path: CallHistoryReader.databasePath, data: calls),
            FileSpec(domain: ContactsReader.domain, path: ContactsReader.databasePath, data: contacts),
            FileSpec(domain: SafariReader.bookmarksSource.domain, path: SafariReader.bookmarksSource.path, data: bookmarks),
            FileSpec(domain: SafariReader.historySources[0].domain, path: SafariReader.historySources[0].path, data: history),
            FileSpec(domain: MessagesStore.backupSource.domain, path: MessagesStore.backupSource.path, data: try messagesDatabase(scratch, attachmentsRoot: "~/Library/SMS/Attachments")),
            FileSpec(domain: MessagesStore.backupAttachmentDomain, path: "Library/SMS/Attachments/aa/01/IMG_0042.heic", data: Data(repeating: 0xCD, count: 2048)),
            FileSpec(domain: "AppDomain-com.example.notes", path: "Documents/readme.txt", data: Data("hello".utf8)),
        ]
    }

    // MARK: Helpers

    private static func database(_ dir: URL, _ name: String, _ sql: String) throws -> Data {
        let path = dir.appendingPathComponent(UUID().uuidString + "-" + name).path
        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK else { throw SQLiteDB.Failure.open(name) }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        let message = err.map { String(cString: $0) }
        sqlite3_free(err)
        sqlite3_close(db)
        guard rc == SQLITE_OK else { throw SQLiteDB.Failure.query("\(name): \(message ?? "?")") }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func random(_ n: Int) -> Data { Data((0..<n).map { _ in UInt8.random(in: 0...255) }) }
    private static func be32(_ v: Int) -> Data { Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)]) }
    private static func le32(_ v: Int) -> Data { Data([UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)]) }
    private static func tlv(_ tag: String, _ value: Data) -> Data { Data(tag.utf8) + be32(value.count) + value }
    private static func tlv(_ tag: String, int: Int) -> Data { tlv(tag, be32(int)) }

    /// PKCS#7 padding to the AES block size.
    private static func pad(_ d: Data) -> Data {
        let n = 16 - d.count % 16
        return d + Data(repeating: UInt8(n), count: n)
    }

    private static func field(_ number: Int, _ payload: Data) -> Data {
        var out = Data()
        func varint(_ v: Int) { var v = v; repeat { var b = UInt8(v & 0x7F); v >>= 7; if v > 0 { b |= 0x80 }; out.append(b) } while v > 0 }
        varint(number << 3 | 2)
        varint(payload.count)
        return out + payload
    }

    private static func gzip(_ d: Data) -> Data {
        let deflated = (try? (d as NSData).compressed(using: .zlib) as Data) ?? Data()
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in d {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 != 0 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        crc = ~crc
        let header = Data([0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3])
        let size = UInt32(truncatingIfNeeded: d.count)
        return header + deflated + le32(Int(crc)) + le32(Int(size))
    }

    private static func write(_ plist: [String: Any], to url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
    }
}
#endif
