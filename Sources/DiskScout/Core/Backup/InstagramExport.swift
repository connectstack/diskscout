import Foundation

// Instagram keeps direct messages on its servers and in a private app folder no Mac app can read.
// The authorised route is Meta's own export: Instagram ▸ Settings ▸ Accounts Center ▸ Your
// information and permissions ▸ Download your information. This reads that export (a folder, or
// the .zip as downloaded) in either format Instagram offers:
//   …/messages/inbox/<thread>/message_N.html   (the default)
//   …/messages/inbox/<thread>/message_N.json

final class InstagramExportStore: ConversationStore, @unchecked Sendable {
    enum Failure: LocalizedError {
        case noMessages, unzip(String)
        var errorDescription: String? {
            switch self {
            case .noMessages: return "No messages found here. Choose the .zip Instagram sent you (or the folder it unzips to), and make sure Messages was ticked when you requested the export."
            case .unzip(let m): return "Couldn't open the .zip: \(m)"
            }
        }
    }

    let service = MessagingService.instagram
    let root: URL
    /// Set when the export was a .zip that DiskScout unpacked into a private temporary folder.
    private let unpacked: URL?
    /// Where attachment paths start from: the export's top folder, even if a folder inside it was chosen.
    private var mediaRoot: URL
    private var threadList: [ChatThread] = []
    private var byThread: [String: [ChatMessage]] = [:]
    private(set) var ownerName: String?
    /// Every other page of the export (contacts, followers, logins, ads…), in folder order.
    private(set) var pages: [ExportPageRef] = []
    /// The .zip this was unpacked from, so photos outside the conversations can be fetched when asked for.
    private let archive: URL?
    private let unpackLock = NSLock()
    private var packed: Set<String>?

    init(exportAt url: URL) throws {
        var folder = url
        var temp: URL?
        if url.pathExtension.lowercased() == "zip" {
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScout-backup-instagram-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            do { try Self.unzipMessages(from: url, to: dest) } catch {
                try? FileManager.default.removeItem(at: dest)
                throw error
            }
            folder = dest
            temp = dest
        }
        root = folder.standardizedFileURL
        mediaRoot = root
        unpacked = temp
        archive = temp == nil ? nil : url
        do { try load() } catch { close(); throw error }
        pages = Self.pageList(under: root)
    }

    deinit { close() }

    func close() {
        if let unpacked { try? FileManager.default.removeItem(at: unpacked) }
    }

    private static func run(_ tool: String, _ arguments: [String], logIn folder: URL, output: URL? = nil) throws -> (status: Int32, error: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        // Errors go to a file, not a pipe: a full pipe nobody is reading would stall the tool.
        let log = folder.appendingPathComponent(".unzip-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        p.standardError = try FileHandle(forWritingTo: log)
        if let output {
            FileManager.default.createFile(atPath: output.path, contents: nil)
            p.standardOutput = try FileHandle(forWritingTo: output)
        } else {
            p.standardOutput = FileHandle.nullDevice
        }
        try p.run()
        p.waitUntilExit()
        let text = (try? String(contentsOf: log, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (p.terminationStatus, String(text.suffix(300)))
    }

    /// Unpacks the pages and the conversations' attachments. An export can be many gigabytes of
    /// posts and stories, so those stay packed until one of them is opened.
    static func unzipMessages(from zip: URL, to dest: URL) throws {
        // unzip: 0 = fine, 1 = fine with warnings, 11 = one of the patterns matched nothing (an
        // HTML export has no .json, and the other way round). Whether there are messages is
        // checked by reading what came out.
        let picked = try run("/usr/bin/unzip", ["-qq", "-o", zip.path, "*messages/*", "*.html", "*.json", "-d", dest.path], logIn: dest)
        if [0, 1, 11].contains(picked.status) { return }
        // Anything else (an archive unzip can't read): let ditto unpack all of it.
        let all = try run("/usr/bin/ditto", ["-x", "-k", zip.path, dest.path], logIn: dest)
        guard all.status == 0 else { throw Failure.unzip(all.error.isEmpty ? "the archive is damaged or incomplete" : all.error) }
    }

    /// Fetches one file that was left packed (a post's photo, a story's video).
    private func unpack(_ path: String) {
        guard let archive, let unpacked else { return }
        unpackLock.lock()
        defer { unpackLock.unlock() }
        // Ask the .zip what it holds once, so a file Instagram never included costs nothing to look for.
        if packed == nil {
            let list = unpacked.appendingPathComponent(".contents-\(UUID().uuidString).txt")
            defer { try? FileManager.default.removeItem(at: list) }
            _ = try? Self.run("/usr/bin/unzip", ["-Z1", archive.path], logIn: unpacked, output: list)
            packed = Set(((try? String(contentsOf: list, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init))
        }
        guard packed?.contains(path) == true else { return }
        // unzip reads its file arguments as patterns: take the special characters literally.
        var literal = ""
        for c in path { if "*?[]\\".contains(c) { literal.append("\\") }; literal.append(c) }
        _ = try? Self.run("/usr/bin/unzip", ["-qq", "-o", archive.path, literal, "-d", unpacked.path], logIn: unpacked)
    }

    /// Every HTML page that isn't a conversation, in folder order.
    static func pageList(under root: URL) -> [ExportPageRef] {
        // Paths come back relative to the export, whatever /var or /private/var the folder goes by.
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return [] }
        // Index pages that only link to other pages.
        let skipped: Set<String> = ["start_here.html", "chats.html", "ai_conversations.html", "your_activity_off_meta_technologies.html", "index.html"]
        var out: [ExportPageRef] = []
        for case let relative as String in walker {
            let name = (relative as NSString).lastPathComponent
            let attributes = walker.fileAttributes
            if attributes?[.type] as? FileAttributeType == .typeDirectory {
                // Conversations have their own viewer.
                if name.hasPrefix(".") || ["inbox", "message_requests"].contains(name) { walker.skipDescendants() }
                continue
            }
            guard !name.hasPrefix("."), (name as NSString).pathExtension.lowercased() == "html", !skipped.contains(name) else { continue }
            let parts = relative.split(separator: "/").map(String.init)
            out.append(ExportPageRef(id: relative, title: ExportPageRef.readable((name as NSString).deletingPathExtension),
                                     groups: parts.dropLast().map(ExportPageRef.readable), bytes: (attributes?[.size] as? NSNumber)?.int64Value ?? 0))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    /// The page's own file, to open in a browser as Instagram wrote it.
    func pageFile(_ ref: ExportPageRef) -> URL? {
        let url = root.appendingPathComponent(ref.id).standardizedFileURL
        return url.path.hasPrefix(root.path + "/") && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func page(_ ref: ExportPageRef) throws -> ExportPage {
        guard let url = pageFile(ref), let data = FileManager.default.contents(atPath: url.path) else { throw Failure.noMessages }
        var page = InstagramHTML.page(data)
        if page.title == nil { page.title = ref.title }
        return page
    }

    /// A photo or video named on a page, as a path inside the export.
    func mediaFile(_ path: String) -> URL? { fileURL(forURI: path) }

    /// A conversation's pages inside its folder, in order: JSON if the export has it, else HTML.
    static func messageFiles(in folder: URL) -> (files: [URL], isJSON: Bool) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("message_") }
        for ext in [".json", ".html"] {
            let picked = names.filter { $0.hasSuffix(ext) }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if !picked.isEmpty { return (picked.map { folder.appendingPathComponent($0) }, ext == ".json") }
        }
        return ([], false)
    }

    /// Folders that hold a conversation, anywhere under an "inbox" folder.
    static func threadFolders(under root: URL) -> [URL] {
        var out: [URL] = []
        var inboxes: [URL] = []
        if root.lastPathComponent == "inbox" { inboxes.append(root) }
        if let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard url.lastPathComponent == "inbox", (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                walker.skipDescendants()
                inboxes.append(url)
            }
        }
        for inbox in inboxes {
            for child in ((try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil)) ?? []).sorted(by: { $0.path < $1.path })
            where !messageFiles(in: child).files.isEmpty {
                out.append(child)
            }
        }
        return out
    }

    /// Meta's JSON writes UTF-8 bytes as if they were Latin-1 characters ("Ã©" for "é"). Undo that.
    static func repair(_ s: String) -> String {
        guard let latin = s.data(using: .isoLatin1), let fixed = String(data: latin, encoding: .utf8) else { return s }
        return fixed
    }

    /// One message as either format gives it, before deciding who "me" is.
    private struct RawMessage {
        var sender: String?
        var date: Date?
        var text: String?
        var links: [String] = []
        var media: [(uri: String, kind: ChatAttachment.Kind)] = []
    }

    private struct RawThread {
        let id: String
        var title: String
        var participants: [String]
        /// Oldest first.
        var messages: [RawMessage]
    }

    private static func readJSON(_ files: [URL], id: String) -> RawThread? {
        var thread: RawThread?
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let people = ((json["participants"] as? [[String: Any]]) ?? []).compactMap { ($0["name"] as? String).map(repair) }
            var messages: [RawMessage] = []
            for m in (json["messages"] as? [[String: Any]]) ?? [] {
                var raw = RawMessage(sender: (m["sender_name"] as? String).map(repair),
                                     date: (m["timestamp_ms"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                                     text: (m["content"] as? String).map(repair))
                for (key, kind) in [("photos", ChatAttachment.Kind.image), ("videos", .video), ("audio_files", .audio), ("gifs", .video), ("files", .document)] {
                    for item in (m[key] as? [[String: Any]]) ?? [] {
                        if let uri = item["uri"] as? String { raw.media.append((uri, kind)) }
                    }
                }
                if let share = m["share"] as? [String: Any], let link = share["link"] as? String {
                    raw.links.append(link)
                    if raw.text == nil { raw.text = (share["share_text"] as? String).map(repair) }
                }
                messages.append(raw)
            }
            if thread == nil {
                thread = RawThread(id: id, title: (json["title"] as? String).map(repair) ?? id, participants: people, messages: messages)
            } else {
                thread?.messages.append(contentsOf: messages)
            }
        }
        return thread
    }

    private static func readHTML(_ files: [URL], id: String) -> (thread: RawThread, base: URL?)? {
        var thread: RawThread?
        var base: URL?
        var listed: [String] = []
        for file in files {
            guard let data = FileManager.default.contents(atPath: file.path) else { continue }
            let page = InstagramHTML.parse(data)
            if base == nil, let href = page.base, !href.contains("://") {
                base = URL(fileURLWithPath: href, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
            }
            if listed.isEmpty { listed = page.participants }
            let messages = page.messages.map { RawMessage(sender: $0.sender, date: $0.date, text: $0.text, links: $0.links, media: $0.media) }
            if thread == nil {
                thread = RawThread(id: id, title: page.title ?? id, participants: [], messages: messages)
            } else {
                thread?.messages.append(contentsOf: messages)
            }
        }
        guard var thread else { return nil }
        // HTML has no member list for one-to-one chats: the people are whoever wrote something.
        var seen = Set<String>()
        let senders = thread.messages.compactMap(\.sender).filter { seen.insert($0).inserted }
        thread.participants = listed.count > senders.count ? listed : senders
        return (thread, base)
    }

    private func load() throws {
        let folders = Self.threadFolders(under: root)
        guard !folders.isEmpty else { throw Failure.noMessages }

        var raws: [RawThread] = []
        var appearances: [String: Int] = [:]
        for folder in folders {
            let (files, isJSON) = Self.messageFiles(in: folder)
            var raw: RawThread?
            if isJSON {
                raw = Self.readJSON(files, id: folder.lastPathComponent)
            } else if let html = Self.readHTML(files, id: folder.lastPathComponent) {
                raw = html.thread
                if mediaRoot == root, let base = html.base, FileManager.default.fileExists(atPath: base.path) { mediaRoot = base }
            }
            guard var raw, !raw.messages.isEmpty else { continue }
            // Both formats list the newest message first. Turn that round, then order by time;
            // messages in the same minute (HTML has no seconds) keep the order they were written in.
            raw.messages = raw.messages.reversed().enumerated()
                .sorted { a, b in
                    let (x, y) = (a.element.date ?? .distantPast, b.element.date ?? .distantPast)
                    return x == y ? a.offset < b.offset : x < y
                }
                .map(\.element)
            raws.append(raw)
            for p in Set(raw.participants) { appearances[p, default: 0] += 1 }
        }
        guard !raws.isEmpty else { throw Failure.noMessages }
        // Who is "me"? In a one-to-one chat the title is the other person's name, so the participant
        // who isn't the title is the account owner. Fall back to whoever is in the most conversations,
        // but only when that's unambiguous.
        var votes: [String: Int] = [:]
        for raw in raws where raw.participants.count == 2 && raw.participants.contains(raw.title) {
            if let me = raw.participants.first(where: { $0 != raw.title }) { votes[me, default: 0] += 1 }
        }
        if let best = votes.max(by: { $0.value < $1.value }) {
            ownerName = best.key
        } else if raws.count > 1, let top = appearances.values.max(), appearances.values.filter({ $0 == top }).count == 1 {
            ownerName = appearances.first { $0.value == top }?.key
        } else {
            ownerName = nil
        }

        for raw in raws {
            var messages: [ChatMessage] = []
            var mediaCount = 0
            var mediaBytes: Int64 = 0
            for (i, m) in raw.messages.enumerated() {
                var attachments: [ChatAttachment] = []
                for item in m.media {
                    let file = fileURL(forURI: item.uri)
                    let size = file.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? NSNumber }?.int64Value ?? 0
                    attachments.append(ChatAttachment(kind: item.kind, title: (item.uri as NSString).lastPathComponent, size: size, locator: file == nil ? nil : item.uri))
                    mediaCount += 1
                    mediaBytes += size
                }
                for link in m.links { attachments.append(ChatAttachment(kind: .link, title: link, size: 0, locator: nil)) }
                guard m.text != nil || !attachments.isEmpty else { continue }
                messages.append(ChatMessage(id: "\(raw.id)#\(i)", date: m.date, fromMe: m.sender != nil && m.sender == ownerName,
                                            sender: m.sender, text: m.text, isSystem: false, attachments: attachments))
            }
            let others = raw.participants.filter { $0 != ownerName }
            byThread[raw.id] = messages
            threadList.append(ChatThread(id: raw.id, service: .instagram, title: raw.title, detail: others.count > 1 ? others.joined(separator: ", ") : nil,
                                         isGroup: others.count > 1, lastDate: messages.last?.date, messageCount: messages.count,
                                         mediaCount: mediaCount, mediaBytes: mediaBytes))
        }
        threadList.sort { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    /// Media paths are relative to the export's top folder. Nothing outside the export is served.
    private func fileURL(forURI uri: String) -> URL? {
        let url = mediaRoot.appendingPathComponent(uri).standardizedFileURL
        guard url.path.hasPrefix(mediaRoot.path + "/") else { return nil }
        if !FileManager.default.fileExists(atPath: url.path), archive != nil, mediaRoot == root {
            unpack(String(url.path.dropFirst(mediaRoot.path.count + 1)))
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func threads() throws -> [ChatThread] { threadList }

    func messages(in thread: String, limit: Int) throws -> [ChatMessage] {
        Array((byThread[thread] ?? []).suffix(max(1, limit)))
    }

    func forEachText(_ body: (String, String, Date?, String?, String) -> Void) throws {
        for (thread, messages) in byThread {
            for m in messages { if let t = m.text, !t.isEmpty { body(thread, m.id, m.date, m.fromMe ? "Me" : m.sender, t) } }
        }
    }

    func file(for attachment: ChatAttachment) throws -> URL? {
        attachment.locator.flatMap(fileURL(forURI:))
    }
}
