import XCTest
@testable import DiskScout

final class BackupTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testListsBackups() throws {
        try BackupFixture.make(in: root, udid: "AAAA", deviceName: "Phone A")
        try BackupFixture.make(in: root, udid: "BBBB", deviceName: "Phone B", password: "test-password")
        let list = try BackupStore.list(root: root)
        XCTAssertEqual(Set(list.map(\.deviceName)), ["Phone A", "Phone B"])
        XCTAssertEqual(list.first { $0.udid == "BBBB" }?.isEncrypted, true)
        XCTAssertEqual(list.first { $0.udid == "AAAA" }?.isEncrypted, false)
        XCTAssertTrue(list.allSatisfy(\.isComplete))
        XCTAssertEqual(try BackupStore.list(root: root.appendingPathComponent("missing")), [])
    }

    func testEncryptedBackupRejectsWrongPasswordAndOpensWithRightOne() throws {
        let info = try BackupFixture.make(in: root, password: "correct horse")
        XCTAssertThrowsError(try BackupArchive.open(info, password: nil)) { XCTAssertEqual($0 as? BackupArchive.Failure, .passwordRequired) }
        XCTAssertThrowsError(try BackupArchive.open(info, password: "wrong")) { XCTAssertEqual($0 as? BackupCryptoError, .wrongPassword) }

        let archive = try BackupArchive.open(info, password: "correct horse")
        let work = archive.workDir
        XCTAssertTrue(archive.domains().contains(NotesReader.domain))
        let readme = try XCTUnwrap(archive.entry(domain: "AppDomain-com.example.notes", path: "Documents/readme.txt"))
        let copy = try archive.extractToWork(readme)
        XCTAssertEqual(try String(contentsOf: copy), "hello")
        // Decrypted copies are private to the user.
        let perms = try FileManager.default.attributesOfItem(atPath: work.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o700)
        archive.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path), "decrypted files must be deleted on close")
    }

    func testReadsEverythingFromABackup() throws {
        for password in [nil, "s3cret"] as [String?] {
            let info = try BackupFixture.make(in: root, password: password)
            let archive = try BackupArchive.open(info, password: password)
            defer { archive.close() }

            // WhatsApp
            let wa = try XCTUnwrap(archive.extractDatabase(domain: WhatsAppReader.sources[0].domain, path: WhatsAppReader.databasePath))
            let reader = try WhatsAppReader(databaseAt: wa)
            let chats = try reader.chats()
            XCTAssertEqual(chats.map(\.name), ["Weekend Hikers", "Alex Morgan", "Sam Lee"], "status updates are left out, newest chat first")
            let group = chats[0]
            XCTAssertTrue(group.isGroup)
            XCTAssertEqual(group.messageCount, 4)
            XCTAssertEqual(group.mediaCount, 2)
            XCTAssertEqual(group.mediaBytes, 50_400_000)
            let msgs = try reader.messages(in: group.id)
            XCTAssertEqual(msgs.first?.text, "Who is in for Saturday?")
            XCTAssertEqual(msgs.first?.sender, "Priya Shah")
            XCTAssertEqual(msgs[1].fromMe, true)
            XCTAssertEqual(msgs[2].kind, .image)
            XCTAssertEqual(msgs[2].mediaPath, "Message/Media/120363000000000001@g.us/a/b/photo1.jpg")
            XCTAssertNotNil(archive.entry(domain: WhatsAppReader.sources[0].domain, path: msgs[2].mediaPath!))
            XCTAssertEqual(try reader.search("parcel").count, 1)
            let text = WhatsAppReader.transcript(of: group, messages: msgs)
            XCTAssertTrue(text.contains("Me: Count me in!"))
            XCTAssertTrue(text.contains("<Video: trail.mp4 · 48 MB>"))

            // Notes
            let ns = try XCTUnwrap(archive.extractDatabase(domain: NotesReader.domain, path: NotesReader.databasePath))
            let notesReader = try NotesReader(databaseAt: ns)
            let notes = try notesReader.notes()
            XCTAssertEqual(Set(notes.map(\.title)), ["Grocery list", "Trip ideas", "Private", "Old draft"])
            let grocery = try XCTUnwrap(notes.first { $0.title == "Grocery list" })
            XCTAssertTrue(grocery.isPinned)
            XCTAssertEqual(grocery.folder, "Notes")
            XCTAssertEqual(notesReader.body(of: grocery.id), "Grocery list\nOat milk, apples, coffee beans\n[attachment]\nRemember the receipt")
            XCTAssertTrue(try XCTUnwrap(notes.first { $0.title == "Private" }).isLocked)
            XCTAssertTrue(try XCTUnwrap(notes.first { $0.title == "Old draft" }).inRecentlyDeleted)

            // Calls, with names from the address book and CallKit app names
            let contactsDB = try XCTUnwrap(archive.extractDatabase(domain: ContactsReader.domain, path: ContactsReader.databasePath))
            let contacts = ContactsReader.phoneNames(databaseAt: contactsDB)
            XCTAssertEqual(contacts["5550100001"], "Alex Morgan")
            let callsDB = try XCTUnwrap(archive.extractDatabase(domain: CallHistoryReader.domain, path: CallHistoryReader.databasePath))
            let calls = try CallHistoryReader.calls(databaseAt: callsDB, contacts: contacts, appNames: ["net.whatsapp.WhatsApp": "WhatsApp"])
            XCTAssertEqual(calls.count, 5)
            XCTAssertEqual(calls[0].name, "Alex Morgan")
            XCTAssertEqual(calls[0].direction, "Outgoing")
            XCTAssertEqual(calls.filter(\.missed).count, 2)
            XCTAssertEqual(calls.first { $0.service == "FaceTime Video" }?.duration, 1260)
            XCTAssertEqual(calls.first { $0.service == "WhatsApp" }?.name, "Priya Shah")
            XCTAssertEqual(calls.first { $0.service == "WhatsApp" }?.number, "+15550100003")
            XCTAssertEqual(CallHistoryReader.serviceName(provider: "ph.telegra.Telegraph", callType: 1, appNames: [:]), "Telegram")
            let csv = CallHistoryReader.csv(calls)
            XCTAssertTrue(csv.hasPrefix("Date,Direction,Service,Name,Number,Duration (s),Location\n"))
            XCTAssertEqual(csv.split(separator: "\n").count, 6)

            // Safari
            let bm = try XCTUnwrap(archive.extractDatabase(domain: SafariReader.bookmarksSource.domain, path: SafariReader.bookmarksSource.path))
            let tree = try SafariReader.bookmarks(databaseAt: bm)
            XCTAssertEqual(tree.map(\.title), ["Favorites", "Reading List"])
            XCTAssertEqual(tree[0].children?.map(\.title), ["Apple", "Wikipedia"])
            XCTAssertTrue(SafariReader.bookmarksHTML(tree).contains("<A HREF=\"https://www.apple.com/\">Apple</A>"))
            let hist = try XCTUnwrap(archive.extractDatabase(domain: SafariReader.historySources[0].domain, path: SafariReader.historySources[0].path))
            let visits = try SafariReader.history(databaseAt: hist)
            XCTAssertEqual(visits.count, 4)
            XCTAssertEqual(visits[0].title, "iPhone - Apple")
            XCTAssertEqual(visits[0].host, "www.apple.com")
        }
    }

    func testReadsThisMacsCopiesWithoutABackup() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try BackupFixture.makeMacHome(in: home)
        let mac = try MacSyncedData(home: home)
        let work = mac.workDir
        XCTAssertTrue(mac.includesCallAndBrowsingHistory)

        let wa = try XCTUnwrap(mac.whatsappDatabase())
        XCTAssertEqual(wa.appName, "WhatsApp")
        let reader = try WhatsAppReader(databaseAt: wa.url)
        let chats = try reader.chats()
        XCTAssertEqual(chats.count, 3)
        // The live database is never opened: DiskScout reads its own private copy.
        XCTAssertTrue(wa.url.path.hasPrefix(work.path))
        let photo = try reader.messages(in: chats[0].id).first { $0.kind == .image }
        XCTAssertNotNil(try mac.mediaFile(scope: wa.mediaScope, path: try XCTUnwrap(photo?.mediaPath)))

        let notes = try NotesReader(databaseAt: try XCTUnwrap(mac.notesDatabase())).notes()
        XCTAssertEqual(notes.count, 4)

        let contacts = mac.contactNames()
        XCTAssertEqual(contacts["5550100002"], "Sam Lee")
        let calls = try CallHistoryReader.calls(databaseAt: try XCTUnwrap(mac.callHistoryDatabase()), contacts: contacts)
        XCTAssertEqual(calls.first { $0.missed }?.name, "Sam Lee")

        let bookmarks = try XCTUnwrap(mac.safariBookmarks())
        XCTAssertEqual(bookmarks.map(\.title), ["Favorites", "Reading List"], "the History proxy is skipped")
        XCTAssertEqual(bookmarks[0].children?.map(\.title), ["Apple", "Wikipedia"])
        let history = try XCTUnwrap(mac.safariHistory())
        XCTAssertEqual(history.filter(\.fromOtherDevice).count, 2)
        XCTAssertEqual(history.first?.title, "iPhone - Apple")

        mac.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testMissingMacAppsAreReportedAsMissing() throws {
        let empty = root.appendingPathComponent("empty-home", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let mac = try MacSyncedData(home: empty)
        defer { mac.close() }
        XCTAssertNil(try mac.whatsappDatabase())
        XCTAssertNil(try mac.notesDatabase())
        XCTAssertNil(try mac.callHistoryDatabase())
        XCTAssertNil(try mac.safariBookmarks())
        XCTAssertNil(try mac.safariHistory())
        XCTAssertEqual(mac.contactNames(), [:])
    }

    func testCSVEscaping() {
        XCTAssertEqual(CSV.field("plain"), "plain")
        XCTAssertEqual(CSV.field("a, b"), "\"a, b\"")
        XCTAssertEqual(CSV.field("say \"hi\""), "\"say \"\"hi\"\"\"")
    }

    func testWhatsAppMediaPaths() {
        XCTAssertEqual(WhatsAppReader.backupPath(forMedia: "Media/x/y.jpg"), "Message/Media/x/y.jpg")
        XCTAssertEqual(WhatsAppReader.backupPath(forMedia: "/Media/x/y.jpg"), "Message/Media/x/y.jpg")
        XCTAssertEqual(WhatsAppReader.backupPath(forMedia: "/var/mobile/Containers/Shared/AppGroup/ABC/Message/Media/x/y.jpg"), "Message/Media/x/y.jpg")
        XCTAssertEqual(WhatsAppReader.readable(jid: "15550100001@s.whatsapp.net"), "+15550100001")
    }
}
