import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Everything in an Instagram export besides the conversations: contacts, followers, logins, ads,
// likes, searches, stories viewed… A list of the export's pages on the left, the chosen page's
// entries on the right.

struct InstagramExportBrowser: View {
    @ObservedObject var session: BackupSession
    @State private var pageFilter = ""

    /// A top folder of the export, with its pages grouped by the folders beneath it.
    private struct Category: Identifiable {
        let id: String
        var groups: [Group]
        var count: Int { groups.reduce(0) { $0 + $1.pages.count } }
    }

    private struct Group: Identifiable {
        let id: String
        let name: String
        var pages: [ExportPageRef]
    }

    /// What people look for first comes first; the advertising pages come last.
    private static let order = ["Connections", "Personal information", "Your instagram activity", "Security and login information",
                                "Logged information", "Preferences", "Media", "Ads information", "Apps and websites off of instagram"]

    private static func icon(_ category: String) -> String {
        switch category {
        case "Connections": return "person.2.fill"
        case "Personal information": return "person.text.rectangle.fill"
        case "Your instagram activity": return "heart.text.square.fill"
        case "Security and login information": return "lock.shield.fill"
        case "Logged information": return "clock.arrow.circlepath"
        case "Preferences": return "slider.horizontal.3"
        case "Media": return "photo.on.rectangle"
        case "Ads information": return "megaphone.fill"
        case "Apps and websites off of instagram": return "globe"
        default: return "doc.text.fill"
        }
    }

    private var categories: [Category] {
        let q = pageFilter.trimmingCharacters(in: .whitespaces).lowercased()
        var byCategory: [String: [String: [ExportPageRef]]] = [:]
        for page in session.exportPages where q.isEmpty || page.title.lowercased().contains(q) || page.groups.joined(separator: " ").lowercased().contains(q) {
            let category = page.groups.first ?? "Other"
            byCategory[category, default: [:]][page.groups.dropFirst().joined(separator: " › "), default: []].append(page)
        }
        func rank(_ name: String) -> Int { Self.order.firstIndex(of: name) ?? Self.order.count }
        return byCategory.map { name, groups in
            Category(id: name, groups: groups.map { Group(id: name + "/" + $0.key, name: $0.key, pages: $0.value) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
        .sorted { rank($0.id) == rank($1.id) ? $0.id < $1.id : rank($0.id) < rank($1.id) }
    }

    var body: some View {
        if session.exportPages.isEmpty {
            EmptyState(systemImage: "doc.text.magnifyingglass", title: "Only messages in this export",
                       message: "This export is in JSON format, and DiskScout reads its messages. To browse the contacts, followers, logins and everything else here, request the export again in HTML format (Instagram's default).",
                       tint: .secondary)
        } else {
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).font(.system(size: 11))
                        TextField("Find a page", text: $pageFilter).textFieldStyle(.plain).font(.system(size: 12))
                        if !pageFilter.isEmpty {
                            Button { pageFilter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 7)
                    Divider()
                    List(selection: Binding(get: { session.selectedExportPage }, set: { session.openExportPage($0) })) {
                        ForEach(categories) { category in
                            Section {
                                ForEach(category.groups) { group in
                                    // A folder of dozens of near-identical pages (one per business) folds away.
                                    if group.pages.count > 12 {
                                        DisclosureGroup {
                                            ForEach(group.pages) { row($0) }
                                        } label: {
                                            Text("\(group.name.components(separatedBy: " › ").last ?? group.name) · \(group.pages.count)")
                                                .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                    } else {
                                        if category.groups.count > 1, !group.name.isEmpty {
                                            Text(group.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary).lineLimit(1)
                                                .padding(.top, 3).selectionDisabled()
                                        }
                                        ForEach(group.pages) { row($0) }
                                    }
                                }
                            } header: {
                                Label("\(category.id) · \(category.count)", systemImage: Self.icon(category.id))
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                    }
                    .listStyle(.inset)
                }
                .frame(width: 300)
                Divider()
                if let id = session.selectedExportPage, let ref = session.exportPages.first(where: { $0.id == id }) {
                    ExportPageView(session: session, ref: ref).id(ref.id)
                } else {
                    EmptyState(systemImage: "tray.full.fill", title: "Everything else in the export",
                               message: "\(session.exportPages.count.formatted()) pages Instagram included besides your messages: synced contacts, followers and following, logins and devices, searches, likes, comments, stories viewed, and what advertisers know. Choose one on the left.",
                               tint: MessagingService.instagram.color)
                }
            }
        }
    }

    private func row(_ page: ExportPageRef) -> some View {
        Text(page.title).font(.system(size: 12.5)).lineLimit(1).truncationMode(.middle)
            .padding(.vertical, 1)
            .tag(page.id)
    }
}

private struct ExportPageView: View {
    @ObservedObject var session: BackupSession
    let ref: ExportPageRef
    @State private var filter = ""
    /// The entries that match the filter, and which of them start a new list heading.
    @State private var shown: [ExportEntry] = []
    @State private var headers: Set<Int> = []
    /// How many of them are in the list so far. "Stories viewed" can run past ten thousand, and a
    /// list that long makes every redraw of the window expensive, so more arrive as you scroll.
    @State private var limit = ExportPageView.batch
    private static let batch = 250

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(session.exportPage.value?.title ?? ref.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    Text(subtitle).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                Button { exportCSV() } label: { Label("Export CSV…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize().disabled(session.exportPage.value == nil)
                    .help("Save what's listed here as a spreadsheet")
                Button { if let url = session.exportPageFile(ref.id) { NSWorkspace.shared.open(url) } } label: { Image(systemName: "safari") }
                    .buttonStyle(.bordered).controlSize(.small).fixedSize()
                    .help("Open the page as Instagram wrote it, in your browser")
            }
            .padding(.horizontal, 14).padding(.vertical, 7)
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 11))
                TextField("Filter this page", text: $filter).textFieldStyle(.plain).font(.system(size: 12))
                if !filter.isEmpty {
                    Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            Divider()
            if let page = session.exportPage.value {
                if page.entries.isEmpty {
                    EmptyState(systemImage: "tray", title: "Nothing on this page", message: "Instagram included the page but left it empty.", tint: .secondary)
                } else if shown.isEmpty {
                    EmptyState(systemImage: "magnifyingglass", title: "No matches", message: "Nothing on this page contains “\(filter)”.", tint: .secondary)
                } else {
                    List {
                        ForEach(shown.prefix(limit)) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                if headers.contains(entry.id), let section = entry.section {
                                    Text(section).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
                                }
                                ExportEntryRow(session: session, entry: entry)
                            }
                        }
                        if shown.count > limit {
                            // Reaching the end of what's listed brings in the next batch.
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Showing \(limit.formatted()) of \(shown.count.formatted()). Scroll for more, or filter.")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                                Spacer()
                                Button("Show More") { limit += Self.batch }.buttonStyle(.link).font(.system(size: 11))
                            }
                            .padding(.vertical, 6)
                            .id(limit)
                            .onAppear { limit += Self.batch }
                        }
                    }
                    .listStyle(.inset)
                }
            } else if session.exportPage.loading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading \(ref.title.lowercased())…").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = session.exportPage.error {
                EmptyState(systemImage: "exclamationmark.triangle.fill", title: "Couldn't read this page", message: error, tint: SafetyLevel.caution.color)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { refilter() }
        .onChange(of: filter) { _, _ in refilter() }
        .onChange(of: session.exportPage.value?.entries.count) { _, _ in refilter() }
    }

    private var subtitle: String {
        let place = ref.groups.joined(separator: " › ")
        guard let page = session.exportPage.value else { return place }
        let count = filter.isEmpty ? "\(page.entries.count.formatted()) entr\(page.entries.count == 1 ? "y" : "ies")"
                                   : "\(shown.count.formatted()) of \(page.entries.count.formatted()) entries"
        return "\(count) · \(place)"
    }

    private func refilter() {
        let all = session.exportPage.value?.entries ?? []
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        shown = q.isEmpty ? all : all.filter { $0.search.contains(q) }
        limit = Self.batch
        var starts = Set<Int>()
        var previous: String?
        for entry in shown {
            if entry.section != nil, entry.section != previous { starts.insert(entry.id) }
            previous = entry.section
        }
        headers = starts
    }

    private func exportCSV() {
        guard let page = session.exportPage.value else { return }
        // Everything that matches the filter, not only the part listed so far.
        let entries = shown.isEmpty ? page.entries : shown
        Exporter.save(ExportCSV.text(entries), suggestedName: "Instagram – \(Exporter.fileName(page.title ?? ref.title)).csv", type: .commaSeparatedText)
    }
}

/// One page's entries as a spreadsheet: a column per field name, in the order they first appear.
enum ExportCSV {
    static func text(_ entries: [ExportEntry]) -> String {
        var labels: [String] = []
        var seen = Set<String>()
        for entry in entries { for field in entry.fields where seen.insert(field.label).inserted { labels.append(field.label) } }
        let iso = ISO8601DateFormatter()
        var out = (["Title", "Date"] + labels + ["Text", "Links", "Media"]).map(CSV.field).joined(separator: ",") + "\n"
        for entry in entries {
            var values: [String: String] = [:]
            for field in entry.fields { values[field.label] = values[field.label].map { $0 + ", " + field.value } ?? field.value }
            var row: [String] = [entry.title ?? "", entry.date.map { iso.string(from: $0) } ?? ""]
            for label in labels { row.append(values[label] ?? "") }
            row.append(entry.texts.joined(separator: "\n"))
            row.append(entry.links.joined(separator: " "))
            row.append(entry.media.joined(separator: " "))
            out += row.map(CSV.field).joined(separator: ",") + "\n"
        }
        return out
    }
}

private struct ExportEntryRow: View {
    @ObservedObject var session: BackupSession
    let entry: ExportEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.headline).font(.system(size: 12.5, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if let date = entry.date {
                    Text(DateFormat.medium.string(from: date)).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                }
            }
            ForEach(Array(entry.texts.enumerated()), id: \.offset) { _, text in
                if text != entry.headline {
                    Text(text).font(.system(size: 12)).textSelection(.enabled).lineLimit(8)
                }
            }
            ForEach(Array(entry.fields.enumerated()), id: \.offset) { _, field in
                if field.value != entry.headline || entry.fields.count == 1 {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(field.label).font(.system(size: 11)).foregroundStyle(.secondary)
                            .frame(width: 170, alignment: .leading).lineLimit(2)
                        if field.value.lowercased().hasPrefix("http"), !field.value.contains(" "), let url = URL(string: field.value) {
                            Link(destination: url) { Text(Self.short(field.value)).font(.system(size: 11.5)).lineLimit(1).truncationMode(.middle) }
                                .help(field.value)
                        } else {
                            Text(field.value).font(.system(size: 11.5)).textSelection(.enabled).lineLimit(6)
                        }
                    }
                }
            }
            if !entry.media.isEmpty {
                HStack(spacing: 6) {
                    ForEach(entry.media.prefix(8), id: \.self) { ExportThumb(session: session, path: $0) }
                    if entry.media.count > 8 { Text("+\(entry.media.count - 8)").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
                .padding(.top, 2)
            }
            // Links that no field above already shows.
            let extra = entry.links.filter { link in !entry.fields.contains { $0.value == link } }
            if !extra.isEmpty {
                HStack(spacing: 10) {
                    ForEach(extra.prefix(3), id: \.self) { link in
                        if let url = URL(string: link) {
                            Link(destination: url) {
                                Label(Self.short(link), systemImage: "link").font(.system(size: 10.5)).lineLimit(1).truncationMode(.middle)
                            }
                            .help(link)
                        }
                    }
                    if extra.count > 3 { Text("+\(extra.count - 3) more").font(.system(size: 10.5)).foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.vertical, 3)
    }

    /// "instagram.com/p/ABC…" rather than a full tracking URL.
    private static func short(_ link: String) -> String {
        guard let c = URLComponents(string: link), let host = c.host else { return link }
        let text = host.replacingOccurrences(of: "www.", with: "") + c.path
        return text.count > 46 ? String(text.prefix(45)) + "…" : text
    }
}

/// A photo or video from the export. Click to open it in Quick Look.
private struct ExportThumb: View {
    @ObservedObject var session: BackupSession
    let path: String
    @State private var url: URL?
    @State private var image: NSImage?
    @State private var missing = false

    var body: some View {
        Button {
            if let url { QuickLookController.shared.toggle([url]) } else { NSSound.beep() }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(Theme.subtleFill)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if missing {
                    Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.tertiary)
                } else {
                    ProgressView().controlSize(.mini)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(missing ? "Instagram didn't include this file in the export" : (path as NSString).lastPathComponent)
        .task(id: path) {
            guard let found = await session.exportMedia(path) else { missing = true; return }
            url = found
            image = await ThumbnailLoader.shared.thumbnail(for: found, size: 56)
        }
    }
}
