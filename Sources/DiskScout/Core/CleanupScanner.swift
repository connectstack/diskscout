import Foundation
import SwiftUI
import AppKit

enum CleanupCategory: String, CaseIterable, Identifiable, Hashable {
    case trash = "Trash"
    case appCaches = "App Caches"
    case browsers = "Browser Caches"
    case logs = "Logs & Crash Reports"
    case xcode = "Xcode & Simulators"
    case devTools = "Developer Caches"
    case leftovers = "Leftovers from Uninstalled Apps"
    case installers = "Installers & Disk Images"
    case mail = "Mail Attachment Copies"
    case backups = "iPhone & iPad Backups"
    case misc = "Other Junk"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .trash: return "trash.fill"
        case .appCaches: return "memorychip.fill"
        case .browsers: return "safari.fill"
        case .logs: return "doc.text.fill"
        case .xcode: return "hammer.fill"
        case .devTools: return "terminal.fill"
        case .leftovers: return "app.dashed"
        case .installers: return "shippingbox.fill"
        case .mail: return "paperclip"
        case .backups: return "iphone.gen3"
        case .misc: return "sparkles"
        }
    }

    var color: Color {
        switch self {
        case .trash: return Color(red: 0.55, green: 0.58, blue: 0.68)
        case .appCaches: return Color(red: 0.36, green: 0.58, blue: 1.00)
        case .browsers: return Color(red: 0.27, green: 0.72, blue: 0.95)
        case .logs: return Color(red: 0.62, green: 0.67, blue: 0.78)
        case .xcode: return Color(red: 0.45, green: 0.84, blue: 0.47)
        case .devTools: return Color(red: 0.30, green: 0.70, blue: 0.60)
        case .leftovers: return Color(red: 0.74, green: 0.47, blue: 1.00)
        case .installers: return Color(red: 0.96, green: 0.56, blue: 0.27)
        case .mail: return Color(red: 0.40, green: 0.60, blue: 0.95)
        case .backups: return Color(red: 1.00, green: 0.62, blue: 0.20)
        case .misc: return Color(red: 0.95, green: 0.45, blue: 0.60)
        }
    }

    var blurb: String {
        switch self {
        case .trash: return "Files you already deleted. Emptying frees the space for real."
        case .appCaches: return "Temporary data apps keep to launch faster. Rebuilt automatically."
        case .browsers: return "Cached web pages and images. You stay signed in to websites."
        case .logs: return "Diagnostic text files. Only useful while troubleshooting a problem."
        case .xcode: return "Build intermediates, device symbols and simulator caches Xcode recreates."
        case .devTools: return "Package caches for npm, Homebrew, pip, Gradle, Docker and friends."
        case .leftovers: return "Settings and data from apps that are no longer installed."
        case .installers: return "Disk images and packages for apps you've probably already installed."
        case .mail: return "Copies of attachments you opened. The originals stay in Mail."
        case .backups: return "Full device backups made by Finder. Keep the ones you still need."
        case .misc: return "Window state, old software updates and other regenerable bits."
        }
    }
}

enum CleanupAction: Hashable {
    case moveToTrash
    case emptyTrash
}

struct CleanupItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let title: String
    let subtitle: String
    let size: Int64
    let assessment: SafetyAssessment
    let category: CleanupCategory
    let action: CleanupAction
    let isDirectory: Bool
    var modified: Date?

    var name: String { url.lastPathComponent }
}

@MainActor
final class CleanupScanner: ObservableObject {
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var completed: Set<CleanupCategory> = []
    @Published private(set) var currentCategory: CleanupCategory?
    @Published private(set) var lastScan: Date?
    @Published private(set) var elapsed: TimeInterval = 0
    @Published var hasScanned = false

    /// The last scan was stopped before it finished, so the list may be incomplete.
    @Published private(set) var wasStopped = false

    private var task: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var startedAt = Date()
    /// Identifies the running scan, so a cancelled one can't touch the state of its replacement.
    private var generation = 0

    // MARK: - Aggregates

    func items(in category: CleanupCategory) -> [CleanupItem] {
        items.filter { $0.category == category }.sorted { $0.size > $1.size }
    }

    func total(in category: CleanupCategory) -> Int64 {
        items.filter { $0.category == category }.reduce(0) { $0 + $1.size }
    }

    func total(level: SafetyLevel) -> Int64 {
        items.filter { $0.assessment.level == level }.reduce(0) { $0 + $1.size }
    }

    var totalSafe: Int64 { total(level: .safe) }
    var totalAll: Int64 { items.reduce(0) { $0 + $1.size } }

    var categoriesWithItems: [CleanupCategory] {
        CleanupCategory.allCases.filter { c in items.contains { $0.category == c } }
    }

    func remove(_ item: CleanupItem) {
        items.removeAll { $0.id == item.id }
    }

    func remove(urls: Set<String>) {
        items.removeAll { urls.contains($0.url.path) }
    }

    func cancel() {
        task?.cancel()
        ticker?.cancel()
        generation += 1
        if isScanning { wasStopped = true }
        isScanning = false
        currentCategory = nil
    }

    // MARK: - Scan

    func scan() {
        cancel()
        let scanID = generation
        wasStopped = false
        isScanning = true
        hasScanned = true
        items = []
        completed = []
        elapsed = 0
        startedAt = Date()

        ticker = Task { [weak self] in
            while !Task.isCancelled, let self, self.isScanning {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let home = AppPaths.home
            let installed = InstalledApps.snapshot()
            for category in CleanupCategory.allCases {
                if Task.isCancelled { break }
                await MainActor.run { [weak self] in if self?.generation == scanID { self?.currentCategory = category } }
                let candidates = Self.candidates(for: category, home: home, installed: installed)
                let sized = await Self.size(candidates)
                if Task.isCancelled { break }
                await MainActor.run { [weak self] in
                    guard let self, self.generation == scanID, self.isScanning else { return }
                    withAnimation(.spring(duration: 0.5)) {
                        self.items.append(contentsOf: sized)
                        self.completed.insert(category)
                    }
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.generation == scanID else { return }   // stopped or superseded
                self.isScanning = false
                self.currentCategory = nil
                self.lastScan = Date()
                self.ticker?.cancel()
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }
    }

    // MARK: - Candidates

    struct Candidate {
        let url: URL
        let title: String
        let subtitle: String
        let category: CleanupCategory
        var action: CleanupAction = .moveToTrash
        var minSize: Int64 = 1_000_000
        var assessmentOverride: SafetyAssessment? = nil
    }

    nonisolated private static let browserCachePaths: [(String, String)] = [
        ("Library/Caches/com.apple.Safari", "Safari"),
        ("Library/Containers/com.apple.Safari/Data/Library/Caches", "Safari"),
        ("Library/Caches/Google/Chrome", "Google Chrome"),
        ("Library/Caches/com.google.Chrome", "Google Chrome"),
        ("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", "Google Chrome (service workers)"),
        ("Library/Caches/Firefox", "Firefox"),
        ("Library/Caches/Microsoft Edge", "Microsoft Edge"),
        ("Library/Caches/com.microsoft.edgemac", "Microsoft Edge"),
        ("Library/Caches/BraveSoftware", "Brave"),
        ("Library/Caches/com.brave.Browser", "Brave"),
        ("Library/Caches/company.thebrowser.Browser", "Arc"),
        ("Library/Caches/com.operasoftware.Opera", "Opera"),
        ("Library/Caches/com.vivaldi.Vivaldi", "Vivaldi"),
        ("Library/Caches/Chromium", "Chromium"),
    ]

    /// Items under ~/Library/Caches that belong to another category.
    nonisolated private static let cachesHandledElsewhere: Set<String> = [
        "Homebrew", "CocoaPods", "pip", "Yarn", "yarn", "go-build", "com.apple.dt.Xcode", "JetBrains", "ms-playwright",
        "Google", "com.google.Chrome", "Firefox", "Microsoft Edge", "com.microsoft.edgemac", "BraveSoftware", "com.brave.Browser",
        "company.thebrowser.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "Chromium", "com.apple.Safari"
    ]

    nonisolated private static func candidates(for category: CleanupCategory, home: URL, installed: InstalledApps) -> [Candidate] {
        let fm = FileManager.default
        func h(_ rel: String) -> URL { home.appendingPathComponent(rel) }
        func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
        func children(_ url: URL, hidden: Bool = false) -> [URL] {
            (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: hidden ? [] : [.skipsHiddenFiles])) ?? []
        }
        var out: [Candidate] = []

        switch category {
        case .trash:
            let trash = h(".Trash")
            out.append(Candidate(url: trash, title: "Trash", subtitle: "Empty the Trash to free this space", category: .trash, action: .emptyTrash, minSize: 1))

        case .appCaches:
            let caches = h("Library/Caches")
            for c in children(caches) where !cachesHandledElsewhere.contains(c.lastPathComponent) {
                let name = c.lastPathComponent
                let pretty = installed.displayName(forBundleID: name) ?? (bundleIDIfReverseDNS(name) != nil ? installed.prettyName(forOrphan: name) : name)
                out.append(Candidate(url: c, title: pretty, subtitle: "~/Library/Caches/\(name)", category: .appCaches, minSize: 2_000_000))
            }
            // Sandboxed app caches
            for container in children(h("Library/Containers")) {
                let cache = container.appendingPathComponent("Data/Library/Caches")
                if exists(cache) {
                    let id = container.lastPathComponent
                    if id == "com.apple.Safari" || id == "com.apple.mail" { continue }
                    let pretty = installed.displayName(forBundleID: id) ?? installed.prettyName(forOrphan: id)
                    out.append(Candidate(url: cache, title: pretty, subtitle: "Sandboxed cache · \(id)", category: .appCaches, minSize: 5_000_000))
                }
            }

        case .browsers:
            for (rel, name) in browserCachePaths {
                let url = h(rel)
                if exists(url) {
                    out.append(Candidate(url: url, title: name, subtitle: "~/" + rel, category: .browsers, minSize: 1_000_000))
                }
            }

        case .logs:
            for c in children(h("Library/Logs")) {
                out.append(Candidate(url: c, title: c.lastPathComponent, subtitle: "~/Library/Logs/\(c.lastPathComponent)", category: .logs, minSize: 500_000))
            }

        case .xcode:
            let dev = h("Library/Developer")
            guard exists(dev) else { break }
            for c in children(dev.appendingPathComponent("Xcode/DerivedData")) {
                let name = c.lastPathComponent
                let pretty = name.split(separator: "-").dropLast().joined(separator: "-")
                out.append(Candidate(url: c, title: pretty.isEmpty ? name : String(pretty), subtitle: "DerivedData · build intermediates", category: .xcode, minSize: 1_000_000))
            }
            for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
                for c in children(dev.appendingPathComponent("Xcode/\(platform) DeviceSupport")) {
                    out.append(Candidate(url: c, title: "\(platform) \(c.lastPathComponent)", subtitle: "Device support symbols · re-downloaded when needed", category: .xcode, minSize: 1_000_000))
                }
            }
            let archives = dev.appendingPathComponent("Xcode/Archives")
            if exists(archives) { out.append(Candidate(url: archives, title: "Xcode Archives", subtitle: "Shipped builds · needed to symbolicate crashes", category: .xcode, minSize: 10_000_000)) }
            let simCaches = dev.appendingPathComponent("CoreSimulator/Caches")
            if exists(simCaches) { out.append(Candidate(url: simCaches, title: "Simulator caches", subtitle: "CoreSimulator/Caches", category: .xcode, minSize: 1_000_000)) }
            let simDevices = dev.appendingPathComponent("CoreSimulator/Devices")
            if exists(simDevices) { out.append(Candidate(url: simDevices, title: "Simulator devices", subtitle: "All simulated iPhones, iPads and Watches", category: .xcode, minSize: 50_000_000)) }
            for name in ["XCTestDevices", "XCPGDevices"] {
                let u = dev.appendingPathComponent(name)
                if exists(u) { out.append(Candidate(url: u, title: name, subtitle: "Temporary simulator clones", category: .xcode, minSize: 10_000_000)) }
            }
            let previews = dev.appendingPathComponent("Xcode/UserData/Previews")
            if exists(previews) { out.append(Candidate(url: previews, title: "SwiftUI Previews cache", subtitle: "Xcode/UserData/Previews", category: .xcode, minSize: 10_000_000)) }
            let xcodeCache = h("Library/Caches/com.apple.dt.Xcode")
            if exists(xcodeCache) { out.append(Candidate(url: xcodeCache, title: "Xcode cache", subtitle: "~/Library/Caches/com.apple.dt.Xcode", category: .xcode, minSize: 5_000_000)) }
            let docs = dev.appendingPathComponent("Xcode/DocumentationCache")
            if exists(docs) { out.append(Candidate(url: docs, title: "Documentation cache", subtitle: "Xcode/DocumentationCache", category: .xcode, minSize: 10_000_000)) }

        case .devTools:
            let list: [(String, String, String)] = [
                (".npm/_cacache", "npm cache", "~/.npm/_cacache"),
                (".gradle/caches", "Gradle caches", "~/.gradle/caches"),
                (".cargo/registry", "Cargo registry", "~/.cargo/registry"),
                ("Library/Caches/CocoaPods", "CocoaPods cache", "~/Library/Caches/CocoaPods"),
                (".cocoapods/repos", "CocoaPods specs", "~/.cocoapods/repos"),
                ("Library/Caches/Homebrew", "Homebrew downloads", "~/Library/Caches/Homebrew"),
                ("Library/Caches/pip", "pip cache", "~/Library/Caches/pip"),
                (".pub-cache", "Dart / Flutter packages", "~/.pub-cache"),
                ("Library/Caches/go-build", "Go build cache", "~/Library/Caches/go-build"),
                ("go/pkg/mod", "Go module cache", "~/go/pkg/mod"),
                (".m2/repository", "Maven repository", "~/.m2/repository"),
                ("Library/Caches/Yarn", "Yarn cache", "~/Library/Caches/Yarn"),
                (".yarn/berry/cache", "Yarn Berry cache", "~/.yarn/berry/cache"),
                ("Library/Caches/ms-playwright", "Playwright browsers", "~/Library/Caches/ms-playwright"),
                ("Library/Caches/JetBrains", "JetBrains IDE caches", "~/Library/Caches/JetBrains"),
                (".ollama/models", "Ollama models", "~/.ollama/models"),
                (".cache/huggingface", "Hugging Face models", "~/.cache/huggingface"),
                (".cache/pip", "pip cache", "~/.cache/pip"),
                (".cache/puppeteer", "Puppeteer browsers", "~/.cache/puppeteer"),
                (".cache/uv", "uv cache", "~/.cache/uv"),
                (".cache/pre-commit", "pre-commit environments", "~/.cache/pre-commit"),
                (".cache/typescript", "TypeScript cache", "~/.cache/typescript"),
                (".cache/node-gyp", "node-gyp headers", "~/.cache/node-gyp"),
                (".cache/electron", "Electron downloads", "~/.cache/electron"),
                (".cache/yarn", "Yarn cache", "~/.cache/yarn"),
                (".bun/install/cache", "Bun cache", "~/.bun/install/cache"),
                (".pnpm-store", "pnpm store", "~/.pnpm-store"),
                ("Library/pnpm/store", "pnpm store", "~/Library/pnpm/store"),
                ("Library/Containers/com.docker.docker/Data/vms", "Docker disk image", "Images, containers and volumes"),
                (".android/avd", "Android emulators", "~/.android/avd"),
                ("Library/Android/sdk/system-images", "Android system images", "~/Library/Android/sdk/system-images"),
                ("Library/Application Support/Code/CachedData", "VS Code cached data", "Application Support/Code/CachedData"),
                ("Library/Application Support/Code/CachedExtensionVSIXs", "VS Code extension downloads", "Application Support/Code/CachedExtensionVSIXs"),
                (".rustup/toolchains", "Rust toolchains", "~/.rustup/toolchains"),
                (".nvm/.cache", "nvm downloads", "~/.nvm/.cache"),
                ("Library/Caches/Cypress", "Cypress binaries", "~/Library/Caches/Cypress"),
                ("Library/Caches/com.microsoft.VSCode", "VS Code cache", "~/Library/Caches/com.microsoft.VSCode"),
            ]
            for (rel, title, subtitle) in list {
                let u = h(rel)
                if exists(u) { out.append(Candidate(url: u, title: title, subtitle: subtitle, category: .devTools, minSize: 2_000_000)) }
            }

        case .leftovers:
            out.append(contentsOf: leftoverCandidates(home: home, installed: installed))

        case .installers:
            let exts: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso"]
            for folder in [h("Downloads"), h("Desktop")] {
                for f in children(folder) where exts.contains(f.pathExtension.lowercased()) {
                    out.append(Candidate(url: f, title: f.lastPathComponent, subtitle: "~/\(folder.lastPathComponent) · installer", category: .installers, minSize: 100_000))
                }
            }

        case .mail:
            let md = h("Library/Containers/com.apple.mail/Data/Library/Mail Downloads")
            if exists(md) { out.append(Candidate(url: md, title: "Mail Downloads", subtitle: "Attachment copies opened from Mail", category: .mail, minSize: 1_000_000)) }

        case .backups:
            let backups = h("Library/Application Support/MobileSync/Backup")
            for b in children(backups) {
                var title = b.lastPathComponent
                var subtitle = "Device backup"
                let info = b.appendingPathComponent("Info.plist")
                if let data = try? Data(contentsOf: info),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                    if let name = plist["Device Name"] as? String { title = name }
                    var bits: [String] = []
                    if let product = plist["Product Name"] as? String { bits.append(product) }
                    if let v = plist["Product Version"] as? String { bits.append("iOS \(v)") }
                    if let date = plist["Last Backup Date"] as? Date { bits.append("backed up \(DateFormat.relativeString(date))") }
                    if !bits.isEmpty { subtitle = bits.joined(separator: " · ") }
                }
                out.append(Candidate(url: b, title: title, subtitle: subtitle, category: .backups, minSize: 10_000_000))
            }

        case .misc:
            let list: [(String, String, String, Int64)] = [
                ("Library/Saved Application State", "Saved window state", "Which windows each app had open", 5_000_000),
                ("Library/iTunes/iPhone Software Updates", "iPhone software updates", "Old iOS update downloads", 1_000_000),
                ("Library/Application Support/CrashReporter", "Crash reporter data", "Crash bookkeeping", 5_000_000),
                ("Music/iTunes/iTunes Media/Mobile Applications", "Legacy iOS app backups", "iTunes-era .ipa files", 10_000_000),
                ("Library/Application Support/Adobe/Common/Media Cache Files", "Adobe media cache", "Premiere / After Effects previews", 50_000_000),
                ("Library/Application Support/Adobe/Common/Media Cache", "Adobe media cache database", "Premiere / After Effects previews", 50_000_000),
                ("Library/Application Support/Spotify/PersistentCache", "Spotify cache", "Streaming cache (check offline downloads first)", 50_000_000),
                ("Library/Application Support/Slack/Cache", "Slack cache", "Cached images and files", 20_000_000),
                ("Library/Application Support/Slack/Service Worker/CacheStorage", "Slack web cache", "Cached web data", 20_000_000),
                ("Library/Application Support/discord/Cache", "Discord cache", "Cached images and files", 20_000_000),
                ("Library/Application Support/Microsoft/Teams/Cache", "Teams cache", "Cached web data", 20_000_000),
                ("Library/Application Support/zoom.us/AutoUpdater", "Zoom update downloads", "Old installers", 10_000_000),
                ("Library/Application Support/Steam/steamapps/shadercache", "Steam shader cache", "Rebuilt when games run", 50_000_000),
                ("Library/Group Containers/group.com.apple.notes/Accounts/LocalAccount/Media", "", "", Int64.max), // placeholder never shown
            ]
            for (rel, title, subtitle, min) in list where min != Int64.max {
                let u = h(rel)
                if exists(u) { out.append(Candidate(url: u, title: title, subtitle: subtitle, category: .misc, minSize: min)) }
            }
        }
        return out
    }

    // MARK: - Leftovers

    nonisolated private static let leftoverFolders: [(String, String, (String) -> String?)] = [
        ("Library/Application Support", "Application Support", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Caches", "Caches", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Containers", "Containers", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Group Containers", "Group Containers", { name in
            var n = name
            if n.hasPrefix("group.") { n = String(n.dropFirst(6)) }
            else if let dot = n.firstIndex(of: "."), n[n.startIndex..<dot].count == 10, n[n.startIndex..<dot].allSatisfy({ $0.isUppercase || $0.isNumber }) { n = String(n[n.index(after: dot)...]) }
            return bundleIDIfReverseDNS(n)
        }),
        ("Library/Preferences", "Preferences", { name in
            guard name.hasSuffix(".plist") else { return nil }
            return bundleIDIfReverseDNS(String(name.dropLast(6)))
        }),
        ("Library/Saved Application State", "Saved Application State", { name in
            guard name.hasSuffix(".savedState") else { return nil }
            return bundleIDIfReverseDNS(String(name.dropLast(11)))
        }),
        ("Library/HTTPStorages", "HTTPStorages", { name in
            var n = name
            if n.hasSuffix(".binarycookies") { n = String(n.dropLast(14)) }
            return bundleIDIfReverseDNS(n)
        }),
        ("Library/WebKit", "WebKit", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Logs", "Logs", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Application Scripts", "Application Scripts", { name in bundleIDIfReverseDNS(name) }),
        ("Library/Cookies", "Cookies", { name in
            var n = name
            if n.hasSuffix(".binarycookies") { n = String(n.dropLast(14)) }
            return bundleIDIfReverseDNS(n)
        }),
    ]

    nonisolated private static func bundleIDIfReverseDNS(_ name: String) -> String? {
        let parts = name.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let tld = parts[0].lowercased()
        let knownTLDs: Set<String> = ["com", "org", "net", "io", "dev", "app", "co", "de", "uk", "me", "us", "fr", "ch", "nl", "se", "no", "fi", "dk", "at", "es", "it", "pl", "ru", "jp", "cn", "kr", "au", "ca", "nz", "br", "in", "be", "cz", "eu", "info", "biz", "tv", "ai", "sh", "so", "xyz", "cc", "ly", "fm", "gg", "is", "im", "ie", "pt", "tech", "studio", "design", "software", "systems", "tools", "games", "team", "digital", "company", "page", "site", "org", "md", "ag", "ws", "name", "pro", "sg", "hk", "tw", "il", "ua", "hu", "ro", "gr", "tr", "mx", "ar", "cl", "za"]
        guard knownTLDs.contains(tld) || parts[0] == "company" else { return nil }
        guard parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) }) else { return nil }
        return name
    }

    nonisolated private static func leftoverCandidates(home: URL, installed: InstalledApps) -> [Candidate] {
        let fm = FileManager.default
        var out: [Candidate] = []
        for (rel, label, extract) in leftoverFolders {
            let folder = home.appendingPathComponent(rel)
            guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for entry in entries {
                let name = entry.lastPathComponent
                guard let bundleID = extract(name) else { continue }
                if bundleID.lowercased().hasPrefix("com.apple.") || bundleID.hasPrefix("group.com.apple") { continue }
                if installed.isInstalled(bundleID) { continue }
                let pretty = installed.prettyName(forOrphan: bundleID)
                out.append(Candidate(
                    url: entry,
                    title: pretty,
                    subtitle: "\(label) · \(bundleID)",
                    category: .leftovers,
                    minSize: label == "Preferences" ? 20_000 : 200_000,
                    assessmentOverride: SafetyAssessment(.review, "Leftover from an uninstalled app",
                        "No installed app claims the identifier “\(bundleID)”. This is most likely data left behind after you deleted the app. If you plan to reinstall it, keeping this preserves its settings.")
                ))
            }
        }
        return out
    }

    // MARK: - Sizing

    nonisolated private static func size(_ candidates: [Candidate]) async -> [CleanupItem] {
        await withTaskGroup(of: CleanupItem?.self) { group in
            var results: [CleanupItem] = []
            var iterator = candidates.makeIterator()
            func addNext(_ group: inout TaskGroup<CleanupItem?>) {
                guard let c = iterator.next() else { return }
                group.addTask {
                    if Task.isCancelled { return nil }
                    guard let size = DiskWalker.size(of: c.url, cancelled: { Task.isCancelled }), size >= c.minSize else { return nil }
                    var isDir: ObjCBool = false
                    FileManager.default.fileExists(atPath: c.url.path, isDirectory: &isDir)
                    let assessment = c.assessmentOverride ?? SafetyClassifier.assess(url: c.url, isDirectory: isDir.boolValue)
                    let modified = (try? c.url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    return CleanupItem(url: c.url, title: c.title, subtitle: c.subtitle, size: size, assessment: assessment,
                                       category: c.category, action: c.action, isDirectory: isDir.boolValue, modified: modified)
                }
            }
            for _ in 0..<4 { addNext(&group) }
            for await item in group {
                if let item { results.append(item) }
                addNext(&group)
            }
            return results.sorted { $0.size > $1.size }
        }
    }
}

/// Snapshot of installed application bundle identifiers for leftover detection.
struct InstalledApps: @unchecked Sendable {
    let bundleIDs: Set<String>
    let names: [String: String]   // bundleID → display name

    nonisolated static func snapshot() -> InstalledApps {
        var ids = Set<String>()
        var names: [String: String] = [:]
        let fm = FileManager.default
        let home = AppPaths.home
        var roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                     home.appendingPathComponent("Applications").path, "/System/Library/CoreServices", "/Library/Application Support"]
        // Setapp, Homebrew casks, etc.
        roots.append("/Applications/Setapp")
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for e in entries where e.hasSuffix(".app") {
                let plist = "\(root)/\(e)/Contents/Info.plist"
                if let d = NSDictionary(contentsOfFile: plist), let id = d["CFBundleIdentifier"] as? String {
                    ids.insert(id.lowercased())
                    let name = (d["CFBundleDisplayName"] as? String) ?? (d["CFBundleName"] as? String) ?? String(e.dropLast(4))
                    names[id.lowercased()] = name
                }
            }
        }
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { ids.insert(id.lowercased()); if let n = app.localizedName { names[id.lowercased()] = n } }
        }
        return InstalledApps(bundleIDs: ids, names: names)
    }

    nonisolated func isInstalled(_ bundleID: String) -> Bool {
        let lower = bundleID.lowercased()
        if bundleIDs.contains(lower) { return true }
        // Helpers such as com.foo.App.Helper → com.foo.App
        var parts = lower.split(separator: ".").map(String.init)
        while parts.count > 2 {
            parts.removeLast()
            let candidate = parts.joined(separator: ".")
            if bundleIDs.contains(candidate) { return true }
            if bundleIDs.contains(where: { $0.hasPrefix(candidate + ".") }) { return true }
        }
        // Ask LaunchServices as a last resort (covers apps in unusual locations).
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil { return true }
        return false
    }

    nonisolated func displayName(forBundleID id: String) -> String? {
        if let n = names[id.lowercased()] { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return url.deletingPathExtension().lastPathComponent
        }
        return nil
    }

    nonisolated func prettyName(forOrphan id: String) -> String {
        let parts = id.split(separator: ".")
        let last = parts.last.map(String.init) ?? id
        if parts.count >= 3 {
            let vendor = String(parts[1])
            if last.lowercased() == vendor.lowercased() { return last.capitalizedFirst }
            return "\(last.capitalizedFirst) (\(vendor.capitalizedFirst))"
        }
        return last.capitalizedFirst
    }
}

extension String {
    var capitalizedFirst: String {
        guard let f = first else { return self }
        return f.uppercased() + dropFirst()
    }
}
