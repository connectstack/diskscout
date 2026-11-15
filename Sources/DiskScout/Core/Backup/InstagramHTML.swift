import Foundation

// Instagram's export comes as HTML unless you ask for JSON, so most people have the HTML one.
// Each conversation is a page, …/messages/inbox/<thread>/message_N.html:
//
//   <title>thread title</title>
//   <main role="main">
//     <div>                                   one per message, newest first
//       <h2>sender</h2>
//       <div>text, links, photos, reactions</div>
//       <div>Nov 12, 2026 3:45 pm</div>
//     </div>
//
// Meta changes its class names, so this reads the structure, not the classes.

/// A small, forgiving HTML tokenizer: enough for the pages Meta writes. Runs nothing, fetches nothing.
enum HTMLTokens {
    enum Token {
        case open(String, [String: String])
        case close(String)
        case text(String)
    }

    static let voidTags: Set<String> = ["meta", "base", "img", "br", "link", "input", "hr", "source", "area", "col", "embed", "track", "wbr"]

    static func scan(_ data: Data, _ visit: (Token) -> Void) {
        let b = [UInt8](data)
        let n = b.count
        var i = 0
        var textStart = 0
        func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C }
        func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }
        func isNameChar(_ c: UInt8) -> Bool { isLetter(c) || (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x5F || c == 0x3A }
        func flushText(_ end: Int) {
            if end > textStart { visit(.text(decode(String(decoding: b[textStart..<end], as: UTF8.self)))) }
        }
        while i < n {
            guard b[i] == 0x3C, i + 1 < n else { i += 1; continue }   // "<"
            let c = b[i + 1]
            if c == 0x21 || c == 0x3F {   // "<!" comment or doctype, "<?"
                flushText(i)
                if i + 3 < n, b[i + 2] == 0x2D, b[i + 3] == 0x2D {
                    var j = i + 4
                    while j + 2 < n, !(b[j] == 0x2D && b[j + 1] == 0x2D && b[j + 2] == 0x3E) { j += 1 }
                    i = min(n, j + 3)
                } else {
                    while i < n, b[i] != 0x3E { i += 1 }
                    i = min(n, i + 1)
                }
                textStart = i
                continue
            }
            let closing = c == 0x2F
            let nameStart = i + (closing ? 2 : 1)
            guard nameStart < n, isLetter(b[nameStart]) else { i += 1; continue }   // a bare "<" in text
            flushText(i)
            var j = nameStart
            while j < n, isNameChar(b[j]) { j += 1 }
            let name = String(decoding: b[nameStart..<j], as: UTF8.self).lowercased()
            var attrs: [String: String] = [:]
            while j < n, b[j] != 0x3E {
                if isSpace(b[j]) || b[j] == 0x2F { j += 1; continue }
                let keyStart = j
                while j < n, !isSpace(b[j]), b[j] != 0x3D, b[j] != 0x3E, b[j] != 0x2F { j += 1 }
                let key = String(decoding: b[keyStart..<j], as: UTF8.self).lowercased()
                while j < n, isSpace(b[j]) { j += 1 }
                var value = ""
                if j < n, b[j] == 0x3D {
                    j += 1
                    while j < n, isSpace(b[j]) { j += 1 }
                    if j < n, b[j] == 0x22 || b[j] == 0x27 {
                        let quote = b[j]
                        j += 1
                        let start = j
                        while j < n, b[j] != quote { j += 1 }
                        value = String(decoding: b[start..<j], as: UTF8.self)
                        j = min(n, j + 1)
                    } else {
                        let start = j
                        while j < n, !isSpace(b[j]), b[j] != 0x3E { j += 1 }
                        value = String(decoding: b[start..<j], as: UTF8.self)
                    }
                }
                if !key.isEmpty, !closing { attrs[key] = decode(value) }
                if j == keyStart { j += 1 }   // never stall on a stray character
            }
            i = min(n, j + 1)
            textStart = i
            if closing {
                visit(.close(name))
                continue
            }
            visit(.open(name, attrs))
            if name == "style" || name == "script" {
                // Raw text: skip to the closing tag without reading it as markup.
                let end = Array("</\(name)".utf8)
                var k = i
                var found = false
                while k + end.count <= n {
                    if b[k] == 0x3C, (0..<end.count).allSatisfy({ (b[k + $0] | 0x20) == (end[$0] | 0x20) }) { found = true; break }
                    k += 1
                }
                i = found ? k : n
                textStart = i
            }
        }
        flushText(n)
    }

    private static let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}"]

    /// Turns `&amp;`, `&#39;`, `&#x1F600;` and friends back into characters.
    static func decode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            guard let semi = after.prefix(12).firstIndex(of: ";") else {
                out += "&"
                rest = after
                continue
            }
            let entity = after[..<semi]
            var replacement: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                replacement = UInt32(entity.dropFirst(2), radix: 16).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                replacement = UInt32(entity.dropFirst(), radix: 10).flatMap { Unicode.Scalar($0) }.map { String(Character($0)) }
            } else {
                replacement = named[String(entity)]
            }
            if let replacement {
                out += replacement
                rest = after[after.index(after: semi)...]
            } else {
                out += "&"
                rest = after
            }
        }
        out += rest
        return out
    }
}

enum InstagramHTML {
    struct Message {
        var sender: String
        var date: Date?
        var text: String?
        var links: [String] = []
        var media: [(uri: String, kind: ChatAttachment.Kind)] = []
    }

    struct Page {
        var title: String?
        /// The page's `<base href>`: where its media paths start from, relative to the page's folder.
        var base: String?
        /// From the "Participants: a, b, c" line group chats start with.
        var participants: [String] = []
        /// In the order the page lists them (newest first).
        var messages: [Message] = []
    }

    /// The export's header says "UTC", but message times are written in US Pacific time, Meta's
    /// default. Checked against a real export: read as Pacific, the newest message lands minutes
    /// before the export was generated and the quiet hours fall at night; read as UTC, neither holds.
    static let messageTimeZone = TimeZone(identifier: "America/Los_Angeles") ?? TimeZone(secondsFromGMT: -8 * 3600)!

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// "Nov 12, 2026 3:45 pm", and the older "Jan 05, 2021, 3:41:45 PM" / "3:41pm" / 24-hour forms.
    static func date(from text: String, calendar: Calendar) -> Date? {
        var parts = text.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\u{00A0}" || $0 == "\u{202F}" }).map(String.init)
        parts.removeAll { $0 == "at" }
        guard parts.count >= 4, let month = months[String(parts[0].prefix(3))], let day = Int(parts[1]), let year = Int(parts[2]) else { return nil }
        var time = parts[3]
        var meridiem = parts.count > 4 ? parts[4] : ""
        for suffix in ["am", "pm"] where time.hasSuffix(suffix) {
            meridiem = suffix
            time.removeLast(2)
        }
        let clock = time.split(separator: ":").map { Int($0) }
        guard clock.count >= 2, var hour = clock[0], let minute = clock[1], (1...31).contains(day), (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        if meridiem == "pm", hour < 12 { hour += 12 }
        if meridiem == "am", hour == 12 { hour = 0 }
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: clock.count > 2 ? (clock[2] ?? 0) : 0))
    }

    static func kind(forPath path: String) -> ChatAttachment.Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "jpg", "jpeg", "png", "heic", "webp", "gif": return .image
        case "mp4", "mov", "m4v": return .video
        case "m4a", "aac", "mp3", "wav", "ogg", "opus": return .audio
        default: return .document
        }
    }

    static func parse(_ data: Data) -> Page {
        /// One direct child of a message block: the sender heading, a content box, or the date line.
        struct Part {
            var isHeading: Bool
            var lines: [String] = []
            var links: [String] = []
            var media: [(uri: String, kind: ChatAttachment.Kind)] = []
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = messageTimeZone
        var page = Page()
        var stack: [String] = []
        var titleDepth: Int?
        var title = ""
        var mainDepth: Int?
        var sawMain = false
        var blockDepth: Int?
        var parts: [Part] = []
        var buffer = ""
        var reactionsDepth: Int?     // inside a list: who reacted, not part of the message
        var playerDepth: Int?        // inside <video>/<audio>: only a "Click for video" fallback
        var anchor: (href: String, text: String)?

        func isLocal(_ uri: String) -> Bool {
            !uri.isEmpty && !uri.hasPrefix("#") && !uri.contains("://") && !uri.lowercased().hasPrefix("mailto:") && !uri.lowercased().hasPrefix("data:")
        }
        func flushLine() {
            let line = buffer.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).joined(separator: " ") }
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !line.isEmpty else { return }
            if parts.isEmpty { parts.append(Part(isHeading: false)) }
            parts[parts.count - 1].lines.append(line)
        }
        func addMedia(_ uri: String, _ kind: ChatAttachment.Kind) {
            let path = uri.removingPercentEncoding ?? uri
            if parts.isEmpty { parts.append(Part(isHeading: false)) }
            guard !parts[parts.count - 1].media.contains(where: { $0.uri == path }) else { return }
            parts[parts.count - 1].media.append((path, kind))
        }
        func finishBlock() {
            flushLine()
            defer { parts = []; reactionsDepth = nil; playerDepth = nil; anchor = nil }
            guard let first = parts.first, first.isHeading else { return }
            let heading = first.lines.joined(separator: " ")
            if parts.count == 1 {
                if let colon = heading.firstIndex(of: ":"), heading[..<colon].lowercased() == "participants" {
                    page.participants = heading[heading.index(after: colon)...].components(separatedBy: ", ")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                }
                return
            }
            // Sender, content, date. Blocks without the date line are thread details, not messages.
            guard parts.count >= 3, !heading.isEmpty else { return }
            var message = Message(sender: heading, date: date(from: parts[parts.count - 1].lines.joined(separator: " "), calendar: calendar))
            var lines: [String] = []
            for part in parts[1..<(parts.count - 1)] {
                lines += part.lines
                message.links += part.links
                message.media += part.media
            }
            message.text = lines.isEmpty ? nil : lines.joined(separator: "\n")
            page.messages.append(message)
        }

        let blockLevel: Set<String> = ["div", "p", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "table", "tr"]

        HTMLTokens.scan(data) { token in
            switch token {
            case .open(let name, let attrs):
                if name == "base", page.base == nil { page.base = attrs["href"] }
                if name == "title", titleDepth == nil, page.title == nil { titleDepth = stack.count }
                if !sawMain, attrs["role"] == "main" || name == "main" {
                    sawMain = true
                    mainDepth = stack.count
                } else if let main = mainDepth, blockDepth == nil, stack.count == main + 1, !HTMLTokens.voidTags.contains(name) {
                    blockDepth = stack.count
                    parts = []
                    buffer = ""
                } else if let block = blockDepth {
                    if stack.count == block + 1 {
                        flushLine()
                        parts.append(Part(isHeading: name.count == 2 && name.hasPrefix("h") && name != "hr"))
                    }
                    switch name {
                    case "br": buffer += "\n"
                    case "ul", "ol":
                        flushLine()
                        if reactionsDepth == nil { reactionsDepth = stack.count }
                    case "a":
                        anchor = (attrs["href"] ?? "", "")
                    case "img":
                        if let src = attrs["src"], isLocal(src) { addMedia(src, .image) }
                    case "video", "audio":
                        if let src = attrs["src"], isLocal(src) { addMedia(src, name == "video" ? .video : .audio) }
                        if playerDepth == nil { playerDepth = stack.count }
                    default:
                        if blockLevel.contains(name) { flushLine() }
                    }
                }
                if !HTMLTokens.voidTags.contains(name) { stack.append(name) }

            case .close(let name):
                guard let index = stack.lastIndex(of: name) else { return }
                stack.removeSubrange(index...)
                if let depth = titleDepth, stack.count <= depth {
                    titleDepth = nil
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    page.title = t.isEmpty ? nil : t
                }
                guard let block = blockDepth else {
                    if let main = mainDepth, stack.count <= main { mainDepth = nil }
                    return
                }
                if name == "a", let a = anchor {
                    anchor = nil
                    let label = a.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if a.href.lowercased().hasPrefix("http") {
                        if parts.isEmpty { parts.append(Part(isHeading: false)) }
                        if !parts[parts.count - 1].links.contains(a.href) { parts[parts.count - 1].links.append(a.href) }
                        if !label.isEmpty, label != a.href, reactionsDepth == nil, playerDepth == nil { buffer += label }
                    } else if isLocal(a.href) {
                        addMedia(a.href, kind(forPath: a.href))
                    } else if !label.isEmpty, reactionsDepth == nil, playerDepth == nil {
                        buffer += label
                    }
                }
                if let depth = reactionsDepth, stack.count <= depth { reactionsDepth = nil }
                if let depth = playerDepth, stack.count <= depth { playerDepth = nil }
                if blockLevel.contains(name) { flushLine() }
                if stack.count <= block {
                    finishBlock()
                    blockDepth = nil
                    if let main = mainDepth, stack.count <= main { mainDepth = nil }
                }

            case .text(let text):
                if titleDepth != nil { title += text; return }
                guard blockDepth != nil, reactionsDepth == nil, playerDepth == nil else { return }
                if anchor != nil { anchor?.text += text } else { buffer += text.replacingOccurrences(of: "\n", with: " ") }
            }
        }
        if blockDepth != nil { finishBlock() }
        return page
    }
}
