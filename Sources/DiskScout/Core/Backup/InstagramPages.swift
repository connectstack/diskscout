import Foundation

// Everything in an Instagram export that isn't a conversation: contacts, followers, logins, ads,
// likes, searches, stories viewed and the rest. About 130 pages, all written the same way:
//
//   <main role="main">
//     <div>                              one per record
//       <h2>optional title</h2>
//       <table> <tr><td>Label<div>value</div></td></tr>
//               <tr><td>Label</td><td>value</td></tr>
//               <tr><td><div><h2>Section</h2><table>…more rows…</table></div></td></tr> </table>
//       <div>Nov 12, 2026 3:45 pm</div>
//     </div>
//
// One reader turns any of them into a list of entries with labelled fields. It follows the
// structure rather than any page's wording, so pages Meta adds later still open.

struct ExportField: Hashable, Sendable {
    var label: String
    var value: String
}

struct ExportEntry: Identifiable, Sendable {
    var id: Int
    var title: String?
    /// Set when one long list on the page (every advertiser, every topic) became one entry per item.
    var section: String?
    var texts: [String] = []
    var fields: [ExportField] = []
    var date: Date?
    var links: [String] = []
    /// Photos and videos, as paths inside the export.
    var media: [String] = []
    /// Lowercased text of everything above, for filtering.
    var search = ""
    /// The one line that names this entry in a list.
    var headline = ""

    /// A title if the page gave one; otherwise the field that reads most like a name.
    func bestHeadline() -> String {
        if let title, !title.isEmpty { return title }
        if let first = texts.first { return first }
        func last(_ f: ExportField) -> String { (f.label.components(separatedBy: " › ").last ?? f.label).lowercased() }
        func plain(_ f: ExportField) -> Bool { !f.value.lowercased().hasPrefix("http") && f.value.count <= 120 }
        // A contact is a first and a last name.
        let names = ["first name", "last name"].compactMap { want in fields.first { last($0) == want }?.value }.filter { !$0.isEmpty }
        if !names.isEmpty { return names.joined(separator: " ") }
        let naming = ["username", "name", "author", "title", "search", "query", "comment", "question", "contact", "owner"]
        if let f = fields.first(where: { f in plain(f) && naming.contains { last(f).contains($0) } }) { return f.value }
        if let f = fields.first(where: plain) { return f.value }
        return fields.first?.value ?? links.first ?? "Entry"
    }
}

struct ExportPage: Sendable {
    var title: String?
    var base: String?
    var entries: [ExportEntry] = []
}

/// One page of the export, by where it sits: "connections/followers_and_following/following.html".
struct ExportPageRef: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    /// The folders above it, made readable: ["Connections", "Followers and following"].
    let groups: [String]
    let bytes: Int64

    /// "followers_and_following" → "Followers and following".
    static func readable(_ name: String) -> String {
        let words = name.replacingOccurrences(of: "_", with: " ").trimmingCharacters(in: .whitespaces)
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

extension InstagramHTML {
    private final class Node {
        let tag: String
        let attrs: [String: String]
        var children: [Item] = []
        init(_ tag: String, _ attrs: [String: String]) { self.tag = tag; self.attrs = attrs }
        var elements: [Node] { children.compactMap { if case .node(let n) = $0 { return n } else { return nil } } }
    }

    private enum Item {
        case node(Node)
        case text(String)
    }

    private static let inlineTags: Set<String> = ["span", "b", "i", "em", "strong", "u", "small", "font", "s", "sup", "sub", "code", "br"]
    private static let headingTags: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    /// A list longer than this becomes one entry per item instead of one enormous field.
    private static let longList = 12

    private static func clean(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\u{00A0}" }).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func rawText(_ node: Node, into out: inout String) {
        for item in node.children {
            switch item {
            case .text(let t): out += t.replacingOccurrences(of: "\n", with: " ")
            case .node(let n):
                if n.tag == "br" { out += "\n"; continue }
                let block = !inlineTags.contains(n.tag) && n.tag != "a"
                if block { out += " " }
                rawText(n, into: &out)
                if block { out += " " }
            }
        }
    }

    private static func text(_ node: Node) -> String {
        var s = ""
        rawText(node, into: &s)
        return clean(s)
    }

    /// The separate pieces of text under a node: one per innermost box.
    private static func leafTexts(_ node: Node, into out: inout [String]) {
        var buffer = ""
        func flush() {
            let t = clean(buffer)
            buffer = ""
            if !t.isEmpty { out.append(t) }
        }
        for item in node.children {
            switch item {
            case .text(let t): buffer += t.replacingOccurrences(of: "\n", with: " ")
            case .node(let n):
                if n.tag == "br" { buffer += "\n" }
                else if inlineTags.contains(n.tag) || n.tag == "a" { rawText(n, into: &buffer) }
                else { flush(); leafTexts(n, into: &out) }
            }
        }
        flush()
    }

    private static func hasText(_ node: Node) -> Bool {
        node.children.contains {
            switch $0 {
            case .text(let t): return !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .node(let n): return hasText(n)
            }
        }
    }

    private static func hasStructure(_ node: Node) -> Bool {
        node.tag == "table" || headingTags.contains(node.tag) || node.elements.contains(where: hasStructure)
    }

    private static func isLocalPath(_ uri: String) -> Bool {
        !uri.isEmpty && !uri.hasPrefix("#") && !uri.contains("://") && !uri.lowercased().hasPrefix("mailto:") && !uri.lowercased().hasPrefix("data:")
    }

    private struct Draft {
        var title: String?
        var texts: [String] = []
        var fields: [(label: String, values: [String])] = []
        var links: [String] = []
        var media: [String] = []
        var footerDate: Date?
        var fieldDate: Date?
    }

    private struct Flattener {
        let calendar: Calendar
        var draft = Draft()

        /// A time as the export writes it (US Pacific) becomes a real moment, shown in this Mac's time.
        mutating func shown(_ value: String) -> String {
            guard value.count <= 40, let date = InstagramHTML.date(from: value, calendar: calendar) else { return value }
            if draft.fieldDate == nil { draft.fieldDate = date }
            return DateFormat.medium.string(from: date)
        }

        mutating func addField(_ path: [String], _ values: [String]) {
            let values = values.map { shown($0) }.filter { !$0.isEmpty }
            guard !values.isEmpty else { return }
            // A section and the one list inside it often carry the same name: say it once.
            var names: [String] = []
            for name in path where name != names.last { names.append(name) }
            let label = names.joined(separator: " › ")
            if let i = draft.fields.firstIndex(where: { $0.label == label }) { draft.fields[i].values += values } else { draft.fields.append((label, values)) }
        }

        mutating func addLoose(_ text: String, _ path: [String]) {
            guard !text.isEmpty else { return }
            if !path.isEmpty { addField(path, [text]); return }
            if text.count <= 40, let date = InstagramHTML.date(from: text, calendar: calendar) { draft.footerDate = date } else { draft.texts.append(text) }
        }

        mutating func addLink(_ href: String) { if !draft.links.contains(href) { draft.links.append(href) } }

        mutating func addMedia(_ uri: String) {
            let path = uri.removingPercentEncoding ?? uri
            guard !path.lowercased().hasSuffix(".html"), !draft.media.contains(path) else { return }
            draft.media.append(path)
        }

        /// Links and pictures anywhere under a node whose text has already been taken.
        mutating func collectRefs(_ node: Node) {
            if node.tag == "a", let href = node.attrs["href"] {
                if href.lowercased().hasPrefix("http") { addLink(href) } else if InstagramHTML.isLocalPath(href) { addMedia(href) }
            }
            if ["img", "video", "audio"].contains(node.tag), let src = node.attrs["src"], InstagramHTML.isLocalPath(src) { addMedia(src) }
            for child in node.elements { collectRefs(child) }
        }

        mutating func visit(_ node: Node, _ path: [String], isRoot: Bool = false) {
            // "Label" followed by boxes of values: one field, or a section when the boxes hold more rows.
            if !isRoot {
                var own = ""
                for case .text(let t) in node.children { own += t.replacingOccurrences(of: "\n", with: " ") }
                own = InstagramHTML.clean(own)
                let boxes = node.elements.filter { !InstagramHTML.inlineTags.contains($0.tag) && $0.tag != "a" }
                if !own.isEmpty, boxes.contains(where: InstagramHTML.hasText) {
                    if boxes.contains(where: InstagramHTML.hasStructure) {
                        for box in boxes { dispatch(box, path + [own], isRoot: false) }
                    } else {
                        var values: [String] = []
                        for box in boxes {
                            InstagramHTML.leafTexts(box, into: &values)
                            collectRefs(box)
                        }
                        addField(path + [own], values)
                    }
                    return
                }
            }
            let outer = path
            var path = path
            var buffer = ""
            for item in node.children {
                switch item {
                case .text(let t):
                    buffer += t.replacingOccurrences(of: "\n", with: " ")
                case .node(let n):
                    if n.tag == "br" { buffer += "\n"; continue }
                    if n.tag == "a" {
                        let href = n.attrs["href"] ?? ""
                        let label = InstagramHTML.text(n)
                        if href.lowercased().hasPrefix("http") {
                            addLink(href)
                            if label != href { buffer += label }
                        } else {
                            if InstagramHTML.isLocalPath(href) { addMedia(href) }
                            buffer += label
                        }
                        for child in n.elements { collectRefs(child) }
                        continue
                    }
                    if InstagramHTML.inlineTags.contains(n.tag) { InstagramHTML.rawText(n, into: &buffer); continue }
                    addLoose(InstagramHTML.clean(buffer), path)
                    buffer = ""
                    if InstagramHTML.headingTags.contains(n.tag) {
                        let heading = InstagramHTML.text(n)
                        collectRefs(n)
                        // The record's own heading is its title; a heading further in names a section.
                        if isRoot, draft.title == nil { draft.title = heading.isEmpty ? nil : heading } else if !heading.isEmpty { path = outer + [heading] }
                    } else {
                        dispatch(n, path, isRoot: false)
                    }
                }
            }
            addLoose(InstagramHTML.clean(buffer), path)
        }

        mutating func dispatch(_ n: Node, _ path: [String], isRoot: Bool) {
            switch n.tag {
            case "table", "tbody", "thead":
                for row in n.elements {
                    if row.tag == "tr" { self.row(row, path) } else { dispatch(row, path, isRoot: false) }
                }
            case "ul", "ol":
                for li in n.elements {
                    addLoose(InstagramHTML.text(li), path)
                    collectRefs(li)
                }
            case "img", "video", "audio":
                if let src = n.attrs["src"], InstagramHTML.isLocalPath(src) { addMedia(src) }
            default:
                visit(n, path, isRoot: isRoot)
            }
        }

        mutating func row(_ tr: Node, _ path: [String]) {
            let cells = tr.elements.filter { $0.tag == "td" || $0.tag == "th" }
            guard cells.count >= 2 else {
                for cell in cells { visit(cell, path) }
                return
            }
            let label = InstagramHTML.text(cells[0])
            collectRefs(cells[0])
            for cell in cells.dropFirst() {
                if label.isEmpty || InstagramHTML.hasStructure(cell) {
                    visit(cell, label.isEmpty ? path : path + [label])
                } else {
                    var values: [String] = []
                    InstagramHTML.leafTexts(cell, into: &values)
                    collectRefs(cell)
                    addField(path + [label], values)
                }
            }
        }
    }

    /// Reads any page of the export into entries.
    static func page(_ data: Data) -> ExportPage {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = messageTimeZone
        var page = ExportPage()
        var stack: [String] = []
        var titleDepth: Int?
        var title = ""
        var mainDepth: Int?
        var sawMain = false
        var blockDepth: Int?
        var root: Node?
        var open: [Node] = []

        var drafts: [Draft] = []
        func finish(_ root: Node) {
            var flattener = Flattener(calendar: calendar)
            flattener.dispatch(root, [], isRoot: true)
            drafts.append(flattener.draft)
        }

        HTMLTokens.scan(data) { token in
            switch token {
            case .open(let name, let attrs):
                let void = HTMLTokens.voidTags.contains(name)
                if name == "base", page.base == nil { page.base = attrs["href"] }
                if name == "title", titleDepth == nil, page.title == nil { titleDepth = stack.count }
                if !sawMain, attrs["role"] == "main" || name == "main" {
                    sawMain = true
                    mainDepth = stack.count
                } else if let main = mainDepth, blockDepth == nil, stack.count == main + 1, !void {
                    blockDepth = stack.count
                    let node = Node(name, attrs)
                    root = node
                    open = [node]
                } else if blockDepth != nil, let parent = open.last {
                    let node = Node(name, attrs)
                    parent.children.append(.node(node))
                    if !void { open.append(node) }
                }
                if !void { stack.append(name) }

            case .close(let name):
                guard let index = stack.lastIndex(of: name) else { return }
                stack.removeSubrange(index...)
                if let depth = titleDepth, stack.count <= depth {
                    titleDepth = nil
                    let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    page.title = t.isEmpty ? nil : t
                }
                if let block = blockDepth {
                    let keep = max(0, stack.count - block)
                    if open.count > keep { open.removeSubrange(keep...) }
                    if stack.count <= block {
                        if let root { finish(root) }
                        root = nil
                        blockDepth = nil
                    }
                }
                if blockDepth == nil, let main = mainDepth, stack.count <= main { mainDepth = nil }

            case .text(let text):
                if titleDepth != nil { title += text; return }
                if blockDepth != nil, let node = open.last { node.children.append(.text(text)) }
            }
        }
        if let root { finish(root) }

        // A page that is one record holding one long list (every advertiser, every topic) reads
        // better as one entry per item. On a page of many records, a long list (a post's hashtags)
        // stays a field of its record.
        let splitLists = drafts.count <= 3
        for d in drafts {
            var entry = ExportEntry(id: page.entries.count, title: d.title, texts: d.texts, date: d.footerDate ?? d.fieldDate, links: d.links, media: d.media)
            var lists: [(label: String, values: [String])] = []
            for field in d.fields {
                if splitLists, field.values.count > longList { lists.append(field) } else { entry.fields.append(ExportField(label: field.label, value: field.values.joined(separator: ", "))) }
            }
            // Thousands of links belong to the list items, not to the record around them.
            if !lists.isEmpty, entry.links.count > longList { entry.links = [] }
            if entry.title != nil || !entry.texts.isEmpty || !entry.fields.isEmpty || !entry.links.isEmpty || !entry.media.isEmpty {
                page.entries.append(entry)
            }
            for list in lists {
                for value in list.values {
                    page.entries.append(ExportEntry(id: page.entries.count, title: value, section: list.label))
                }
            }
        }
        for i in page.entries.indices {
            let e = page.entries[i]
            page.entries[i].headline = e.bestHeadline()
            page.entries[i].search = ([e.title, e.section].compactMap { $0 } + e.texts + e.fields.flatMap { [$0.label, $0.value] } + e.links)
                .joined(separator: "\n").lowercased()
        }
        return page
    }
}
