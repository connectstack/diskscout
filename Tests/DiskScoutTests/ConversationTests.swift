import XCTest
@testable import DiskScout

final class ConversationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("conversation-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Messages

    @available(macOS, deprecated: 10.13)
    func testDecodesTextFromARealAttributedBodyArchive() {
        // The format Messages really writes: an NSAttributedString in a typedstream archive.
        for text in ["Running late", "Emoji 🎉 and accents: café, naïve", String(repeating: "long message ", count: 40)] {
            let real = NSArchiver.archivedData(withRootObject: NSAttributedString(string: text))
            XCTAssertEqual(MessagesStore.text(fromAttributedBody: real), text)
        }
        XCTAssertEqual(MessagesStore.text(fromAttributedBody: BackupFixture.attributedBody("hello")), "hello")
        // Garbage and truncated blobs give nil, never a crash.
        XCTAssertNil(MessagesStore.text(fromAttributedBody: Data([1, 2, 3])))
        XCTAssertNil(MessagesStore.text(fromAttributedBody: Data("xxNSString".utf8)))
        XCTAssertNil(MessagesStore.text(fromAttributedBody: Data("NSString".utf8) + Data([0x01, 0x2B, 0x81, 0xFF])))
        XCTAssertNil(MessagesStore.text(fromAttributedBody: Data("NSString".utf8) + Data([0x01, 0x2B, 0x82, 0xFF, 0xFF, 0xFF, 0x7F, 0x41])))
    }

    private func checkMessages(_ store: MessagesStore) throws {
        let threads = try store.threads()
        // iMessage and SMS rows with the same person merge; the two groups stay separate.
        XCTAssertEqual(threads.count, 3)
        let alex = try XCTUnwrap(threads.first { $0.title == "Alex Morgan" })
        XCTAssertEqual(alex.detail, "+15550100001")
        XCTAssertEqual(alex.messageCount, 5)
        XCTAssertFalse(alex.isGroup)
        XCTAssertEqual(threads.first?.id, alex.id, "newest conversation first")
        let club = try XCTUnwrap(threads.first { $0.title == "Book Club" })
        XCTAssertTrue(club.isGroup)
        XCTAssertEqual(club.mediaCount, 1)
        XCTAssertEqual(club.mediaBytes, 2048)
        // An unnamed group is titled with its members (contact names where known).
        XCTAssertNotNil(threads.first { $0.title == "Sam Lee, priya@example.com" })

        let msgs = try store.messages(in: alex.id, limit: 100)
        XCTAssertEqual(msgs.map(\.text), ["Your code is 482913", "Lunch on Thursday?", "Yes! 12:30 at the usual place", "Running ten minutes late, sorry!"],
                       "text stored only in attributedBody is decoded; the tapback is left out")
        XCTAssertEqual(msgs[2].fromMe, true)
        XCTAssertEqual(msgs[1].sender, "Alex Morgan")

        let clubMsgs = try store.messages(in: club.id, limit: 100)
        XCTAssertEqual(clubMsgs.first?.isSystem, true)
        XCTAssertEqual(clubMsgs.first?.text, "Named the conversation “Book Club”")
        let photo = try XCTUnwrap(clubMsgs.last)
        XCTAssertNil(photo.text, "the attachment placeholder character isn't shown as text")
        XCTAssertEqual(photo.attachments.first?.kind, .image)
        XCTAssertEqual(photo.attachments.first?.title, "IMG_0042.heic")
        let file = try XCTUnwrap(try store.file(for: photo.attachments[0]))
        XCTAssertEqual(try Data(contentsOf: file).count, 2048)

        var indexed: [String] = []
        try store.forEachText { _, _, _, _, text in indexed.append(text) }
        XCTAssertTrue(indexed.contains("Running ten minutes late, sorry!"))
        XCTAssertFalse(indexed.contains { $0.hasPrefix("Liked") })
    }

    func testReadsMessagesFromThisMac() throws {
        let home = root.appendingPathComponent("home", isDirectory: true)
        try BackupFixture.makeMacHome(in: home)
        let mac = try MacSyncedData(home: home)
        defer { mac.close() }
        let db = try XCTUnwrap(mac.messagesDatabase())
        try checkMessages(try MessagesStore(databaseAt: db, contacts: mac.contactNames()) { try mac.messagesAttachment(storedPath: $0) })
        // Only the Messages attachments folder is ever served.
        XCTAssertNil(try mac.messagesAttachment(storedPath: "~/Library/Keychains/login.keychain-db"))
        XCTAssertNil(try mac.messagesAttachment(storedPath: "~/Library/Messages/Attachments/../../Keychains/x"))
        XCTAssertNotNil(mac.changeToken(for: .messages))
        XCTAssertNil(mac.changeToken(for: .calls).flatMap { _ in try? MacSyncedData(home: root.appendingPathComponent("nope")).changeToken(for: .calls) })
    }

    func testReadsMessagesFromAnEncryptedBackup() throws {
        let info = try BackupFixture.make(in: root, password: "pw")
        let archive = try BackupArchive.open(info, password: "pw")
        defer { archive.close() }
        let db = try XCTUnwrap(archive.messagesDatabase())
        try checkMessages(try MessagesStore(databaseAt: db, contacts: archive.contactNames()) { try archive.messagesAttachment(storedPath: $0) })
        XCTAssertNil(archive.changeToken(for: .messages), "a backup never changes underneath us")
    }

    // MARK: Instagram export

    func testReadsInstagramExport() throws {
        let export = root.appendingPathComponent("instagram", isDirectory: true)
        try BackupFixture.makeInstagramExport(in: export)
        let store = try InstagramExportStore(exportAt: export)
        XCTAssertEqual(store.ownerName, "Jamie Rivera")
        let threads = try store.threads()
        XCTAssertEqual(threads.map(\.title), ["Noor Haddad", "Climbing crew"])
        XCTAssertTrue(threads[1].isGroup)
        XCTAssertEqual(threads[0].mediaBytes, 3000)
        let msgs = try store.messages(in: threads[0].id, limit: 100)
        XCTAssertEqual(msgs.last?.text, "That café was great ☕️", "Meta's mis-encoded text is repaired")
        XCTAssertEqual(msgs.last?.fromMe, true)
        XCTAssertEqual(msgs[0].attachments.first?.kind, .link)
        let photo = try XCTUnwrap(msgs[1].attachments.first)
        XCTAssertNotNil(try store.file(for: photo))
        // A path that climbs out of the export is refused.
        XCTAssertNil(try store.file(for: ChatAttachment(kind: .image, title: nil, size: 0, locator: "../../etc/hosts")))
        XCTAssertThrowsError(try InstagramExportStore(exportAt: root.appendingPathComponent("empty")))
    }

    /// Instagram's default export is HTML, not JSON. Same conversations, read from the pages.
    func testReadsInstagramHTMLExport() throws {
        let export = root.appendingPathComponent("instagram-html", isDirectory: true)
        try BackupFixture.makeInstagramHTMLExport(in: export)
        func utc(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

        func check(_ store: InstagramExportStore, _ what: String) throws {
            XCTAssertEqual(store.ownerName, "Jamie Rivera", what)
            let threads = try store.threads()
            XCTAssertEqual(threads.map(\.title), ["Noor Haddad", "Climbing crew"], what)
            XCTAssertFalse(threads[0].isGroup)
            XCTAssertTrue(threads[1].isGroup, "the Participants line counts people who never wrote")
            XCTAssertEqual(threads[0].mediaBytes, 3000, what)

            let msgs = try store.messages(in: threads[0].id, limit: 100)
            XCTAssertEqual(msgs.count, 4, what)
            // The page lists the newest first and has no seconds: same-minute messages keep their order.
            XCTAssertEqual(msgs[0].text, "Noor Haddad started an audio call\nDuration: 12 seconds")
            XCTAssertEqual(msgs[0].date, utc("2026-07-04T07:05:00Z"), "times are written in US Pacific (summer time here)")
            XCTAssertEqual(msgs[1].text, "Noor Haddad sent an attachment.\nLook at this")
            XCTAssertEqual(msgs[1].attachments.map(\.kind), [.link])
            XCTAssertEqual(msgs[1].attachments.first?.title, "https://www.instagram.com/p/EXAMPLE/")
            XCTAssertNil(msgs[2].text)
            let photo = try XCTUnwrap(msgs[2].attachments.first)
            XCTAssertEqual(photo.kind, .image)
            XCTAssertNotNil(try store.file(for: photo), what)
            XCTAssertEqual(msgs[3].text, "That café was great ☕️ & cheap\nSame time next week?", "entities and line breaks; reactions are left out")
            XCTAssertEqual(msgs[3].fromMe, true)
            XCTAssertEqual(msgs[3].date, utc("2026-11-12T23:45:00Z"))
            XCTAssertEqual(msgs[2].fromMe, false)

            let group = try store.messages(in: threads[1].id, limit: 100)
            XCTAssertEqual(group.map(\.text), ["Gym at 7? 1 < 2", "In.", nil], "thread details aren't messages")
            XCTAssertEqual(group[2].attachments.map(\.kind), [.video])
            XCTAssertEqual(group[2].attachments.first?.size, 5000, what)
            XCTAssertNil(try store.file(for: ChatAttachment(kind: .image, title: nil, size: 0, locator: "../../etc/hosts")))
        }

        try check(try InstagramExportStore(exportAt: export), "the unzipped folder")
        // A folder inside the export still finds its photos, through the page's own base path.
        try check(try InstagramExportStore(exportAt: export.appendingPathComponent("your_instagram_activity/messages")), "a folder inside the export")

        // The .zip as downloaded: only conversations are unpacked, not the rest of the export.
        let zip = root.appendingPathComponent("instagram-export.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", export.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 0)
        try check(try InstagramExportStore(exportAt: zip), "the .zip")
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try InstagramExportStore.unzipMessages(from: zip, to: unpacked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("your_instagram_activity/messages/inbox/noor_1001/message_1.html").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("media/posts/202611/holiday.jpg").path))
    }

    /// Everything in the export besides the conversations: one reader for every page.
    func testReadsTheRestOfAnInstagramExport() throws {
        let export = root.appendingPathComponent("instagram-pages", isDirectory: true)
        try BackupFixture.makeInstagramHTMLExport(in: export)
        func utc(_ s: String) -> Date? { ISO8601DateFormatter().date(from: s) }

        func check(_ store: InstagramExportStore, _ what: String) throws {
            XCTAssertEqual(store.pages.map(\.id), [
                "ads_information/instagram_ads_and_businesses/advertisers_using_your_activity_or_information.html",
                "connections/contacts/synced_contacts.html",
                "connections/followers_and_following/following.html",
                "security_and_login_information/login_and_profile_creation/login_activity.html",
                "your_instagram_activity/likes/liked_posts.html",
                "your_instagram_activity/media/posts.html",
            ], "conversations and index pages aren't listed (\(what))")
            func page(_ name: String) throws -> ExportPage { try store.page(try XCTUnwrap(store.pages.first { $0.id.hasSuffix(name) })) }
            XCTAssertEqual(store.pages[2].title, "Following")
            XCTAssertEqual(store.pages[2].groups, ["Connections", "Followers and following"])

            let following = try page("following.html")
            XCTAssertEqual(following.title, "Following")
            XCTAssertEqual(following.entries.map(\.headline), ["noor.h", "leo.climbs", "trail.mix"])
            XCTAssertEqual(following.entries[0].links, ["https://www.instagram.com/_u/noor.h"])
            XCTAssertEqual(following.entries[0].date, utc("2026-11-12T23:45:00Z"), "written in US Pacific")
            XCTAssertTrue(following.entries[0].texts.isEmpty, "a link whose text is its own address isn't repeated")

            let contacts = try page("synced_contacts.html")
            XCTAssertEqual(contacts.entries.map(\.headline), ["Alex Morgan", "Sam Lee", "Priya Shah"])
            XCTAssertEqual(contacts.entries[1].fields, [ExportField(label: "First Name", value: "Sam"), ExportField(label: "Last Name", value: "Lee"),
                                                        ExportField(label: "Contact Information", value: "sam@example.com")])
            XCTAssertTrue(contacts.entries[1].search.contains("sam@example.com"))
            let csv = ExportCSV.text(contacts.entries)
            XCTAssertTrue(csv.hasPrefix("Title,Date,First Name,Last Name,Contact Information,Text,Links,Media\n"))
            XCTAssertTrue(csv.contains(",,Priya,Shah,+1 555 010 0003,,,\n"))

            let logins = try page("login_activity.html")
            XCTAssertEqual(logins.entries.count, 2)
            XCTAssertEqual(logins.entries[0].title, "2026-11-10T17:00:00+00:00")
            XCTAssertEqual(logins.entries[0].fields.map(\.label), ["Cookie Name", "IP Address", "Time", "User Agent"])
            XCTAssertEqual(logins.entries[0].fields[1].value, "203.0.113.7")
            let login = try XCTUnwrap(utc("2026-11-10T17:00:00Z"))
            XCTAssertEqual(logins.entries[0].date, login)
            XCTAssertEqual(logins.entries[0].fields[2].value, DateFormat.medium.string(from: login), "times are shown in this Mac's time, not Pacific")

            // One record holding one long list becomes an entry per item.
            let advertisers = try page("advertisers_using_your_activity_or_information.html")
            XCTAssertEqual(advertisers.entries.count, 15)
            XCTAssertEqual(advertisers.entries[14].headline, "Example Advertiser 15")
            XCTAssertEqual(advertisers.entries[0].section, "Advertisers using your activity or information")

            // On a page of many records a long list stays with its record, and sections name their fields.
            let liked = try page("liked_posts.html")
            XCTAssertEqual(liked.entries.count, 5)
            XCTAssertEqual(liked.entries[0].fields.map(\.label), ["URL", "Caption", "Owner › URL", "Owner › Name", "Owner › Username"])
            XCTAssertEqual(liked.entries[0].headline, "Noor Haddad", "the field that reads most like a name")
            XCTAssertEqual(liked.entries[0].links, ["https://www.instagram.com/p/POST1/", "https://www.instagram.com/noor.h"])
            XCTAssertEqual(liked.entries[1].fields.last?.label, "Hashtags", "a section and its one list share a name")
            XCTAssertEqual(liked.entries[1].fields.last?.value.components(separatedBy: ", ").count, 14)
            XCTAssertEqual(liked.entries[4].date, utc("2026-11-05T15:15:00Z"))

            // A post's photo, even when it was left packed in the .zip.
            let posts = try page("/media/posts.html")
            XCTAssertEqual(posts.entries.count, 1)
            XCTAssertEqual(posts.entries[0].headline, "Weekend in the hills")
            XCTAssertEqual(posts.entries[0].media, ["media/posts/202611/holiday.jpg"])
            let photo = try XCTUnwrap(store.mediaFile(posts.entries[0].media[0]), what)
            XCTAssertEqual(try Data(contentsOf: photo).count, 20_000)
            XCTAssertNil(store.mediaFile("media/posts/202611/not-there.jpg"))
            XCTAssertNil(store.mediaFile("../../etc/hosts"))
        }

        try check(try InstagramExportStore(exportAt: export), "folder")
        let zip = root.appendingPathComponent("instagram-pages.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", export.path, zip.path]
        try p.run()
        p.waitUntilExit()
        try check(try InstagramExportStore(exportAt: zip), "zip")

        // A JSON export has messages but none of these pages.
        let json = root.appendingPathComponent("instagram-json", isDirectory: true)
        try BackupFixture.makeInstagramExport(in: json)
        XCTAssertEqual(try InstagramExportStore(exportAt: json).pages, [])
    }

    func testInstagramDatesAndEntities() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        func at(_ s: String) -> DateComponents? { InstagramHTML.date(from: s, calendar: cal).map { cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: $0) } }
        XCTAssertEqual(at("Nov 12, 2026 3:45 pm"), DateComponents(year: 2026, month: 11, day: 12, hour: 15, minute: 45, second: 0))
        XCTAssertEqual(at("Jul 04, 2026 12:05 am")?.hour, 0)
        XCTAssertEqual(at("Jul 04, 2026 12:05 pm")?.hour, 12)
        XCTAssertEqual(at("Jan 05, 2021, 3:41:45 PM"), DateComponents(year: 2021, month: 1, day: 5, hour: 15, minute: 41, second: 45))
        XCTAssertEqual(at("January 5, 2021 at 15:41")?.hour, 15)
        XCTAssertNil(at("Group invitation link: On"))
        XCTAssertNil(at("https://ig.me/j/EXAMPLE"))
        XCTAssertEqual(HTMLTokens.decode("a &amp; b &lt;3 &#39;x&#39; &#x1F600; &unknown; & alone"), "a & b <3 'x' 😀 &unknown; & alone")
        // Broken markup doesn't hang or crash.
        XCTAssertEqual(InstagramHTML.parse(Data("<main role=main><div><h2>A</h2><div>hi <b".utf8)).messages.count, 0)
        XCTAssertEqual(InstagramHTML.parse(Data()).messages.count, 0)
    }

    /// An export with no conversations fails once and stays failed. The setup screen asks for a
    /// load every time it appears, so a retry here used to spin forever.
    @MainActor
    func testAnUnreadableInstagramExportIsNotRetriedForever() async throws {
        let empty = root.appendingPathComponent("not-an-export", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let session = BackupSession()
        defer { session.forgetInstagramExport() }
        session.openInstagramExport(empty)
        for _ in 0..<200 where session.conversation(.instagram).loading { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(session.conversation(.instagram).error)
        session.load(.instagram)
        XCTAssertFalse(session.conversation(.instagram).loading, "no second attempt on its own")
        XCTAssertNotNil(session.conversation(.instagram).error)
        // Choosing a real export afterwards works.
        let export = root.appendingPathComponent("instagram-html-2", isDirectory: true)
        try BackupFixture.makeInstagramHTMLExport(in: export)
        session.openInstagramExport(export)
        for _ in 0..<200 where session.conversation(.instagram).value == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(session.conversation(.instagram).value?.threads.count, 2)
    }

    /// Counts only, from a real export, when one is pointed at: `DISKSCOUT_INSTAGRAM_EXPORT=<path> swift test`.
    func testRealInstagramExportIfProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["DISKSCOUT_INSTAGRAM_EXPORT"] else { throw XCTSkip("no export given") }
        let started = Date()
        let store = try InstagramExportStore(exportAt: URL(fileURLWithPath: path))
        let threads = try store.threads()
        var messages = 0, undated = 0, mine = 0, withText = 0, links = 0, media = 0, mediaFound = 0, outOfOrder = 0
        var first = Date.distantFuture, last = Date.distantPast
        for t in threads {
            let list = try store.messages(in: t.id, limit: .max)
            messages += list.count
            var previous = Date.distantPast
            for m in list {
                if let d = m.date { first = min(first, d); last = max(last, d); if d < previous { outOfOrder += 1 }; previous = d } else { undated += 1 }
                if m.fromMe { mine += 1 }
                if m.text?.isEmpty == false { withText += 1 }
                for a in m.attachments {
                    if a.kind == .link { links += 1 } else { media += 1; if (try? store.file(for: a)) ?? nil != nil { mediaFound += 1 } }
                }
            }
        }
        print("REAL-EXPORT threads=\(threads.count) groups=\(threads.filter(\.isGroup).count) messages=\(messages) mine=\(mine) withText=\(withText) undated=\(undated) outOfOrder=\(outOfOrder) links=\(links) media=\(media) mediaFound=\(mediaFound) ownerFound=\(store.ownerName != nil) newest=\(ISO8601DateFormatter().string(from: last)) oldestYear=\(Calendar.current.component(.year, from: first)) seconds=\(String(format: "%.2f", Date().timeIntervalSince(started)))")
        XCTAssertGreaterThan(messages, 0)

        // Every other page: counts, and the field names Meta uses (a name only counts as one when
        // most of a page's entries carry it, so no one's data is printed).
        let pagesStarted = Date()
        var entries = 0, empty = 0, dated = 0, withMedia = 0, mediaFound2 = 0, split = 0
        for ref in store.pages {
            let page = try store.page(ref)
            entries += page.entries.count
            if page.entries.isEmpty { empty += 1 }
            var labels: [String: Int] = [:]
            var pageDated = 0, titled = 0, texts = 0, linked = 0, sections = Set<String>()
            for e in page.entries {
                if e.date != nil { dated += 1; pageDated += 1 }
                if e.title != nil { titled += 1 }
                if !e.texts.isEmpty { texts += 1 }
                if !e.links.isEmpty { linked += 1 }
                if let s = e.section { sections.insert(s); split += 1 }
                for f in Set(e.fields.map(\.label)) { labels[f, default: 0] += 1 }
                for m in e.media.prefix(2) { withMedia += 1; if store.mediaFile(m) != nil { mediaFound2 += 1 } }
            }
            let common = labels.filter { $0.value >= max(3, page.entries.count * 6 / 10) }.sorted { $0.value > $1.value }.prefix(7).map { "\($0.key)" }
            let shown = ref.id.contains("your_activity_off_meta_technologies/") ? "apps_and_websites/…/<a business>" : ref.id
            print("PAGE \(page.entries.count) entries (titled \(titled), text \(texts), dated \(pageDated), links \(linked), lists \(sections.count), distinct labels \(labels.count)) \(shown) :: \(common.joined(separator: " | "))")
        }
        print("REAL-PAGES pages=\(store.pages.count) empty=\(empty) entries=\(entries) dated=\(dated) fromLists=\(split) mediaChecked=\(withMedia) mediaFound=\(mediaFound2) seconds=\(String(format: "%.2f", Date().timeIntervalSince(pagesStarted)))")
    }

    // MARK: WhatsApp adapter and transcript

    func testWhatsAppThroughTheSharedModel() throws {
        let home = root.appendingPathComponent("home2", isDirectory: true)
        try BackupFixture.makeMacHome(in: home)
        let mac = try MacSyncedData(home: home)
        defer { mac.close() }
        let db = try XCTUnwrap(mac.whatsappDatabase())
        let scope = db.mediaScope
        let store = WhatsAppStore(reader: try WhatsAppReader(databaseAt: db.url)) { try mac.mediaFile(scope: scope, path: $0) }
        let threads = try store.threads()
        XCTAssertEqual(threads.first?.title, "Weekend Hikers")
        let msgs = try store.messages(in: threads[0].id, limit: 100)
        XCTAssertEqual(msgs[2].attachments.first?.kind, .image)
        XCTAssertNotNil(try store.file(for: msgs[2].attachments[0]))
        let text = ChatTranscript.text(thread: threads[0], messages: msgs)
        XCTAssertTrue(text.contains("Me: Count me in!"))
        XCTAssertTrue(text.contains("<Video: trail.mp4 · 48 MB>"))
    }

    // MARK: Search

    func testSearchQueryParsing() {
        let q = SearchIndex.parse("parcel from:alex in:whatsapp in:notes after:2026-01-01 \"exact words\"")
        XCTAssertEqual(q.match, "\"parcel\"* title : \"alex\"* \"exact words\"")
        XCTAssertEqual(q.services, ["WhatsApp"])
        XCTAssertEqual(q.kinds, [.note])
        XCTAssertNotNil(q.after)
        XCTAssertNil(q.before)
        XCTAssertTrue(SearchIndex.parse("   ").isEmpty)
        // Characters that mean something to the index can't break the query.
        XCTAssertEqual(SearchIndex.parse("a\"b* (c)").match, "\"a b\"* \"c\"*")
    }

    func testSearchFindsAcrossEverything() throws {
        let index = try SearchIndex()
        let old = Date(timeIntervalSince1970: 1_600_000_000), recent = Date(timeIntervalSince1970: 1_780_000_000)
        index.replace(group: "WhatsApp") { add in
            add(.init(kind: .message, service: .whatsapp, ref: "1", thread: "t1", title: "Alex Morgan · Weekend Hikers", body: "Did the parcel arrive?", date: recent))
            add(.init(kind: .message, service: .whatsapp, ref: "2", thread: "t1", title: "Me · Weekend Hikers", body: "Parcels are at the café", date: old))
        }
        index.replace(group: "notes") { add in add(.init(kind: .note, ref: "10", title: "Parcel tracking", body: "Number 1Z999", date: old)) }
        XCTAssertEqual(index.count, 3)

        XCTAssertEqual(index.search("parcel").map(\.ref), ["1", "2", "10"].filter { $0 != "10" } + ["10"], "prefix match, newest first")
        XCTAssertEqual(index.search("cafe").map(\.ref), ["2"], "accents don't matter")
        XCTAssertEqual(index.search("parcel in:notes").map(\.ref), ["10"])
        XCTAssertEqual(index.search("parcel from:alex").map(\.ref), ["1"])
        XCTAssertEqual(index.search("parcel after:2025-01-01").map(\.ref), ["1"])
        XCTAssertEqual(index.search("\"parcel arrive\"").map(\.ref), ["1"])
        XCTAssertTrue(index.search("nothing-like-this").isEmpty)
        for odd in ["a\"b* (c)", "\"unclosed", "AND OR NOT", "col:x", "*", "^", "from:", "((("] { _ = index.search(odd) }
        XCTAssertEqual(index.search("parcel").count, 3, "odd queries leave the index usable")
        XCTAssertTrue(try XCTUnwrap(index.search("arrive").first).snippet.contains("\u{2}arrive\u{3}"))

        // Re-indexing a group replaces it; removing one leaves the others.
        index.replace(group: "WhatsApp") { add in add(.init(kind: .message, service: .whatsapp, ref: "3", thread: "t1", title: "x", body: "fresh")) }
        XCTAssertTrue(index.search("parcel in:whatsapp").isEmpty)
        index.remove(group: "notes")
        XCTAssertEqual(index.count, 1)
    }
}
