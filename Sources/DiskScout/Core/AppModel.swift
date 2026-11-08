import SwiftUI
import AppKit
import Combine

// MARK: - Trash planning

struct TrashCandidate: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let assessment: SafetyAssessment
    let isDirectory: Bool
    let action: CleanupAction
    let nodeID: UUID?

    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }
}

struct TrashPlan: Identifiable {
    let id = UUID()
    let candidates: [TrashCandidate]

    var deletable: [TrashCandidate] { candidates.filter { $0.assessment.canDelete } }
    var blocked: [TrashCandidate] { candidates.filter { !$0.assessment.canDelete } }
    var totalSize: Int64 { deletable.reduce(0) { $0 + $1.size } }
    var hasCaution: Bool { deletable.contains { $0.assessment.level == .caution } }
    var includesEmptyTrash: Bool { deletable.contains { $0.action == .emptyTrash } }
    func count(_ level: SafetyLevel) -> Int { deletable.filter { $0.assessment.level == level }.count }
    func size(_ level: SafetyLevel) -> Int64 { deletable.filter { $0.assessment.level == level }.reduce(0) { $0 + $1.size } }
}

struct TrashFailure: Identifiable {
    var id: String { url.path }
    let name: String
    let url: URL
    let error: String
    /// macOS refused the move for permission reasons (fixable with Full Disk Access or Finder).
    let permission: Bool
}

struct TrashOutcome {
    var moved: [TrashRecord] = []
    var failed: [TrashFailure] = []
    var anyPermissionFailure: Bool { failed.contains { $0.permission } }
    var freed: Int64 = 0
    var emptiedTrash = false
    var batchID: UUID
}

struct Toast: Identifiable, Equatable {
    enum Style { case success, info, error }
    let id = UUID()
    let title: String
    var detail: String? = nil
    var style: Style = .success
    var undoBatch: UUID? = nil
    var autoDismiss: Bool = true
}

enum SortOrder: String, CaseIterable, Identifiable {
    case size = "Size"
    case name = "Name"
    case modified = "Date Modified"
    case safety = "Safety"
    var id: String { rawValue }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let engine = ScanEngine()
    let sizer = SidebarSizer()
    let cleaner = CleanupScanner()
    let trash = TrashManager()
    let license = LicenseManager()
    let settings = AppSettings()

    @Published var mode: ViewMode
    @Published var selectedLocation: SidebarLocation?
    @Published var selection: Set<UUID> = []
    @Published var showInspector: Bool = true
    @Published var trashPlan: TrashPlan?
    @Published var toast: Toast?
    @Published var diskInfo: DiskInfo? = DiskInfo.forRoot()
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .size
    @Published var showWelcome: Bool = false
    @Published var showUpgrade: Bool = false
    @Published var showHistory: Bool = false
    @Published var hasFullDiskAccess: Bool = true
    @Published var fdaBannerDismissed: Bool = false
    @Published var showFullDiskAccessGuide: Bool = false
    @Published var selectedCleanupIDs: Set<String> = []
    @Published var cleanupInspected: CleanupItem?
    /// Folder whose media gallery should open next (consumed by the App scene, which owns `openWindow`).
    @Published var mediaRequest: URL?
    /// A trash plan started from a media gallery window; presented there instead of the main window.
    @Published var mediaTrashPlan: TrashPlan?

    private var toastTask: Task<Void, Never>?
    private var diskTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        mode = ViewMode(rawValue: settings.defaultMode) ?? .smartClean
        hasFullDiskAccess = DiskWalker.hasFullDiskAccess()
        showWelcome = !settings.hasSeenWelcome
        diskTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshDisk() }
        }
        // Views observe the model; re-publish whenever any sub-model changes.
        let publishers: [ObservableObjectPublisher] = [
            engine.objectWillChange, cleaner.objectWillChange, trash.objectWillChange,
            license.objectWillChange, settings.objectWillChange, sizer.objectWillChange
        ]
        for p in publishers {
            p.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
    }

    // MARK: - Lifecycle

    func onAppear() {
        sizer.start(locations: QuickLocations.all)
        if !cleaner.hasScanned { cleaner.scan() }
        applyLaunchArguments()
    }

    /// `DiskScout --scan ~/Downloads --mode treemap` opens straight into a scan.
    private func applyLaunchArguments() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--mode"), i + 1 < args.count,
           let m = ViewMode.allCases.first(where: { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) }) {
            mode = m
        }
        if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
            let path = (args[i + 1] as NSString).expandingTildeInPath
            selectedLocation = QuickLocations.all.first { $0.url.path == path }
            scan(url: URL(fileURLWithPath: path))
            if mode == .smartClean { mode = .browse }
        }
        if let i = args.firstIndex(of: "--media"), i + 1 < args.count {
            let path = (args[i + 1] as NSString).expandingTildeInPath
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                showMedia(in: URL(fileURLWithPath: path))
            }
        }
        #if DEBUG
        if args.contains("--demo-fda") {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 600_000_000)
                openFullDiskAccessSettings()
            }
        }
        if args.contains("--demo-review") {
            Task { @MainActor in
                while engine.isScanning { try? await Task.sleep(nanoseconds: 200_000_000) }
                if let root = engine.root { requestTrash(nodes: Array(root.sortedChildren.prefix(4))) }
            }
        }
        if args.contains("--selftest-trash") {
            Task { @MainActor in await selfTestTrash() }
        }
        #endif
    }

    #if DEBUG
    /// Scripted end-to-end check of scan → plan → trash → undo on throwaway files. Prints to stdout and quits.
    private func selfTestTrash() async {
        func log(_ s: String) { print("[selftest] \(s)"); fflush(stdout) }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".diskscout-selftest-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/pkg"), withIntermediateDirectories: true)
            try Data(count: 50_000).write(to: dir.appendingPathComponent("keep.bin"))
            try Data(count: 80_000).write(to: dir.appendingPathComponent("node_modules/pkg/index.js"))
            try "x".write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        } catch { log("FAIL setup: \(error)"); exit(1) }

        scan(url: dir)
        while engine.isScanning { try? await Task.sleep(nanoseconds: 100_000_000) }
        guard let root = engine.root else { log("FAIL no root"); exit(1) }
        log("scanned \(root.itemCount) items, \(root.size) bytes")
        guard let nm = root.children.first(where: { $0.name == "node_modules" }) else { log("FAIL node_modules missing"); exit(1) }
        log("node_modules assessed as \(nm.assessment.level) — \(nm.assessment.headline)")
        guard nm.assessment.level == .safe, nm.assessment.regenerates else { log("FAIL node_modules should be safe/regenerable"); exit(1) }

        requestTrash(nodes: [nm])
        guard let plan = trashPlan else { log("FAIL no plan (license gate?)"); exit(1) }
        log("plan: \(plan.deletable.count) deletable, \(plan.totalSize) bytes")
        let outcome = await perform(plan) { _, _ in }
        finish(outcome)
        log("moved \(outcome.moved.count), failed \(outcome.failed.count), freed \(outcome.freed)")
        guard outcome.failed.isEmpty, !FileManager.default.fileExists(atPath: nm.url.path) else { log("FAIL trash"); exit(1) }
        guard root.children.first(where: { $0.name == "node_modules" }) == nil, root.itemCount == 2 else { log("FAIL tree not updated: \(root.itemCount)"); exit(1) }

        undo(batch: outcome.batchID)
        guard FileManager.default.fileExists(atPath: nm.url.path) else { log("FAIL undo did not restore"); exit(1) }
        guard root.children.contains(where: { $0.name == "node_modules" }), root.itemCount == 3 else { log("FAIL tree not reinserted: \(root.itemCount)"); exit(1) }
        log("undo restored node_modules; tree has \(root.itemCount) items again")
        try? FileManager.default.removeItem(at: dir)
        log("PASS")
        exit(0)
    }
    #endif

    func refreshDisk() {
        if let info = DiskInfo.forRoot(), info != diskInfo { diskInfo = info }
    }

    func recheckFullDiskAccess() {
        hasFullDiskAccess = DiskWalker.hasFullDiskAccess()
    }

    func refreshFullDiskAccess() {
        let now = DiskWalker.hasFullDiskAccess()
        if now != hasFullDiskAccess {
            hasFullDiskAccess = now
            if now { fdaBannerDismissed = true }
        }
    }

    /// Shows the step-by-step Full Disk Access guide (closing any sheet that's in the way first).
    func openFullDiskAccessSettings() {
        let hadSheet = trashPlan != nil || mediaTrashPlan != nil || showWelcome || showUpgrade
        dismissPlan()
        showWelcome = false
        showUpgrade = false
        if hadSheet {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 450_000_000)
                showFullDiskAccessGuide = true
            }
        } else {
            showFullDiskAccessGuide = true
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens System Settings straight at the Full Disk Access list.
    func openFullDiskAccessPane() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Reveals whatever is running — the .app bundle, or the bare executable for development builds —
    /// so it can be dragged onto the Full Disk Access list.
    func revealSelf() {
        let bundle = Bundle.main.bundleURL
        let target = bundle.pathExtension == "app" ? bundle : (Bundle.main.executableURL ?? bundle)
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    /// Quits and starts DiskScout again (Full Disk Access is applied at launch).
    func relaunch() {
        let bundle = Bundle.main.bundleURL
        let exe = Bundle.main.executableURL ?? bundle
        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let launch = bundle.pathExtension == "app" ? "open \(q(bundle.path))" : "\(q(exe.path)) >/dev/null 2>&1 &"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.7; \(launch)"]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Scanning

    func scan(url: URL) {
        selection = []
        engine.scan(url: url, options: settings.scanOptions)
        if mode == .smartClean { mode = .browse }
    }

    func select(location: SidebarLocation?) {
        selectedLocation = location
        guard let location else { return }
        if location.isSmartClean {
            withAnimation(.snappy) { mode = .smartClean }
            if !cleaner.hasScanned { cleaner.scan() }
        } else {
            scan(url: location.url)
        }
    }

    func rescan() {
        if mode == .smartClean { cleaner.scan(); return }
        if let root = engine.root { scan(url: root.url) }
    }

    func stop() {
        engine.cancel()
        cleaner.cancel()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Pick a folder to scan for space usage"
        if panel.runModal() == .OK, let url = panel.url {
            selectedLocation = nil
            scan(url: url)
        }
    }

    // MARK: - Selection

    var currentChildren: [FileNode] {
        guard let current = engine.current else { return [] }
        var items = current.children
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            items = items.filter { $0.name.lowercased().contains(q) }
        }
        switch sortOrder {
        case .size: items.sort { $0.size > $1.size }
        case .name: items.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified: items.sort { ($0.modificationDate ?? .distantPast) > ($1.modificationDate ?? .distantPast) }
        case .safety: items.sort { ($0.assessment.level, $1.size) < ($1.assessment.level, $0.size) }
        }
        return items
    }

    func selectedNodes(in pool: [FileNode]? = nil) -> [FileNode] {
        let pool = pool ?? currentChildren
        return pool.filter { selection.contains($0.id) }
    }

    /// Resolve selection ids against the whole tree when the pool is unknown (treemap, finder views).
    func nodes(for ids: Set<UUID>) -> [FileNode] {
        guard let root = engine.root else { return [] }
        var out: [FileNode] = []
        var stack = [root]
        while let n = stack.popLast() {
            if ids.contains(n.id) { out.append(n) }
            if out.count == ids.count { break }
            stack.append(contentsOf: n.children)
        }
        return out
    }

    func select(_ node: FileNode, extend: Bool = false, range pool: [FileNode]? = nil, shift: Bool = false) {
        if shift, let pool, let anchorID = selection.first, let a = pool.firstIndex(where: { $0.id == anchorID }), let b = pool.firstIndex(where: { $0.id == node.id }) {
            let r = min(a, b)...max(a, b)
            selection = Set(pool[r].map(\.id))
        } else if extend {
            if selection.contains(node.id) { selection.remove(node.id) } else { selection.insert(node.id) }
        } else {
            selection = [node.id]
        }
        QuickLookController.shared.update(nodes(for: selection).map(\.url))
    }

    func clearSelection() { selection = [] }

    // MARK: - Item actions

    func reveal(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    func quickLook(_ urls: [URL]) {
        QuickLookController.shared.toggle(urls)
    }

    func quickLookSelection() {
        let urls = nodes(for: selection).map(\.url)
        if !urls.isEmpty { quickLook(urls) }
        else if let item = cleanupInspected { quickLook([item.url]) }
    }

    func revealSelection() {
        let urls = nodes(for: selection).map(\.url)
        if !urls.isEmpty { reveal(urls) }
        else if let item = cleanupInspected { reveal([item.url]) }
        else if let cur = engine.current { reveal([cur.url]) }
    }

    /// Opens the media gallery for a folder (or the folder containing a file).
    func showMedia(in url: URL, isDirectory: Bool = true) {
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        mediaRequest = folder
    }

    func showMediaForSelection() {
        let nodes = nodes(for: selection)
        if nodes.count == 1, let n = nodes.first {
            showMedia(in: n.url, isDirectory: n.isDirectory && !n.isPackage)
        } else if let item = cleanupInspected, mode == .smartClean {
            showMedia(in: item.url, isDirectory: item.isDirectory)
        } else if let cur = engine.current {
            showMedia(in: cur.url)
        }
    }

    func copyPath(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        show(Toast(title: "Path copied", detail: url.path, style: .info))
    }

    // MARK: - Trash flow

    func requestTrash(nodes: [FileNode]) {
        guard !nodes.isEmpty else { return }
        guard gateCleaning() else { return }
        let candidates = nodes.map {
            TrashCandidate(url: $0.url, name: $0.name, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isDirectory, action: .moveToTrash, nodeID: $0.id)
        }
        trashPlan = TrashPlan(candidates: candidates)
    }

    func requestTrashSelection() {
        let nodes = nodes(for: selection)
        if !nodes.isEmpty { requestTrash(nodes: nodes); return }
        if mode == .smartClean { requestCleanup(ids: selectedCleanupIDs) }
    }

    /// Trash flow started from a media gallery window.
    func requestTrash(media items: [MediaItem]) {
        guard !items.isEmpty else { return }
        guard gateCleaning() else { return }
        let candidates = items.map {
            TrashCandidate(url: $0.url, name: $0.name, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isPackage, action: .moveToTrash, nodeID: nil)
        }
        mediaTrashPlan = TrashPlan(candidates: candidates)
    }

    func dismissPlan() {
        trashPlan = nil
        mediaTrashPlan = nil
    }

    func requestCleanup(items: [CleanupItem]) {
        guard !items.isEmpty else { return }
        guard gateCleaning() else { return }
        let candidates = items.map {
            TrashCandidate(url: $0.url, name: $0.title, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isDirectory, action: $0.action, nodeID: nil)
        }
        trashPlan = TrashPlan(candidates: candidates)
    }

    func requestCleanup(ids: Set<String>) {
        requestCleanup(items: cleaner.items.filter { ids.contains($0.id) })
    }

    private func gateCleaning() -> Bool {
        if license.canClean { return true }
        showUpgrade = true
        return false
    }

    /// Executes a plan. Runs the file operations off the main thread and reports progress.
    func perform(_ plan: TrashPlan, progress: @escaping @MainActor (Int, Int) -> Void) async -> TrashOutcome {
        let batchID = UUID()
        var outcome = TrashOutcome(batchID: batchID)
        let items = plan.deletable
        for (i, c) in items.enumerated() {
            progress(i, items.count)
            if c.action == .emptyTrash {
                do {
                    try trash.emptyTrash()
                    outcome.emptiedTrash = true
                    outcome.freed += c.size
                    cleaner.remove(urls: [c.url.path])
                } catch {
                    outcome.failed.append(TrashFailure(name: c.name, url: c.url, error: error.localizedDescription, permission: false))
                }
                continue
            }
            do {
                let record = try trash.trash(url: c.url, name: c.name, size: c.size, batchID: batchID)
                outcome.moved.append(record)
                outcome.freed += c.size
                if let id = c.nodeID, let node = nodes(for: [id]).first {
                    engine.remove(node)
                    selection.remove(id)
                } else if let node = engine.node(for: c.url) {
                    engine.remove(node)
                }
                cleaner.remove(urls: [c.url.path])
                selectedCleanupIDs.remove(c.url.path)
                if cleanupInspected?.url == c.url { cleanupInspected = nil }
            } catch {
                let permission = (error as? TrashError)?.isPermission ?? TrashManager.isPermissionError(error as NSError)
                outcome.failed.append(TrashFailure(name: c.name, url: c.url, error: error.localizedDescription, permission: permission))
            }
            // Let the UI breathe on big batches.
            if i % 5 == 4 { await Task.yield() }
        }
        progress(items.count, items.count)
        afterMutation(urls: items.map(\.url))
        return outcome
    }

    func finish(_ outcome: TrashOutcome) {
        dismissPlan()
        let n = outcome.moved.count
        if n == 0 && outcome.emptiedTrash && outcome.failed.isEmpty {
            show(Toast(title: "Trash emptied", detail: "Freed \(outcome.freed.bytesString)", style: .success))
        } else if outcome.failed.isEmpty {
            show(Toast(title: "Moved \(n) item\(n == 1 ? "" : "s") to Trash",
                       detail: "Freed \(outcome.freed.bytesString)" + (outcome.emptiedTrash ? " · Trash emptied" : ""),
                       style: .success, undoBatch: n > 0 ? outcome.batchID : nil))
        } else {
            let first = outcome.failed.first!
            let detail = outcome.anyPermissionFailure
                ? "macOS protects other apps' data. Grant DiskScout Full Disk Access, or delete “\(first.name)” in Finder."
                : "\(first.name): \(first.error)"
            show(Toast(title: "\(outcome.failed.count) item\(outcome.failed.count == 1 ? "" : "s") couldn't be moved",
                       detail: detail, style: .error, undoBatch: n > 0 ? outcome.batchID : nil, autoDismiss: false))
        }
    }

    func undo(batch id: UUID) {
        let result = trash.putBack(batch: id)
        for r in trash.records(inBatch: id) where r.restored {
            // Put the node back into the tree if its parent is visible.
            if let parent = engine.node(for: r.originalURL.deletingLastPathComponent()) {
                reinsert(url: r.originalURL, into: parent)
            }
        }
        afterMutation(urls: trash.records(inBatch: id).map(\.originalURL))
        if result.failures.isEmpty {
            show(Toast(title: "Put back \(result.restored) item\(result.restored == 1 ? "" : "s")", style: .info))
        } else {
            show(Toast(title: "Some items couldn't be put back", detail: result.failures.first, style: .error, autoDismiss: false))
        }
        if mode == .smartClean { cleaner.scan() }
    }

    func putBack(_ record: TrashRecord) {
        do {
            try trash.putBack(record)
            if let parent = engine.node(for: record.originalURL.deletingLastPathComponent()) {
                reinsert(url: record.originalURL, into: parent)
            }
            afterMutation(urls: [record.originalURL])
            show(Toast(title: "Put back “\(record.name)”", style: .info))
        } catch {
            show(Toast(title: "Couldn't put back “\(record.name)”", detail: error.localizedDescription, style: .error, autoDismiss: false))
        }
    }

    /// Rebuilds the restored item's subtree with the scanner so counts and sizes stay exact.
    private func reinsert(url: URL, into parent: FileNode) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if let node = ScanEngine.buildSubtree(url: url, options: settings.scanOptions) {
            engine.insert(node, into: parent)
        }
    }

    private func afterMutation(urls: [URL]) {
        refreshDisk()
        var touched = Set<URL>()
        for url in urls {
            for loc in QuickLocations.all where !loc.isSmartClean && url.path.hasPrefix(loc.url.path) {
                touched.insert(loc.url)
            }
        }
        for u in touched { sizer.refresh(u) }
    }

    // MARK: - Toasts

    func show(_ toast: Toast) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.45, bounce: 0.25)) { self.toast = toast }
        guard toast.autoDismiss else { return }
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(toast.undoBatch == nil ? 3_500_000_000 : 7_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.toast = nil }
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        withAnimation(.easeOut(duration: 0.25)) { toast = nil }
    }
}
