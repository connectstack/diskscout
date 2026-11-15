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

struct DeviceTransfer: Equatable {
    var title: String
    var done: Int64
    var total: Int64
    var fraction: Double { total > 0 ? min(1, Double(done) / Double(total)) : 0 }
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
    let settings = AppSettings()
    let devices = DeviceMonitor()
    /// WhatsApp, Messages, Instagram, Notes, Calls and Safari. Works with or without an iPhone attached.
    let personalData = BackupSession()

    @Published var mode: ViewMode {
        didSet {
            // A selection made in one view must not be acted on from another where it can't be seen.
            // (Browse and Treemap show the same folder, so they share it.)
            let shared: Set<ViewMode> = [.browse, .treemap]
            if oldValue != mode, !(shared.contains(oldValue) && shared.contains(mode)) { selection = [] }
        }
    }
    @Published var selectedLocation: SidebarLocation?
    @Published var selection: Set<UUID> = []
    @Published var showInspector: Bool = true
    @Published var trashPlan: TrashPlan?
    @Published var toast: Toast?
    @Published var diskInfo: DiskInfo? = DiskInfo.forRoot()
    @Published var searchText: String = ""
    @Published var sortOrder: SortOrder = .size
    @Published var showWelcome: Bool = false
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
    /// The connected iPhone/iPad shown in the main area instead of a folder scan.
    @Published var selectedDeviceID: String?
    /// The Messages & Notes view is showing in the main area (no device needed).
    @Published var showingPersonalData = false
    @Published var deviceDeletePlan: DeviceDeletePlan?
    /// A copy from a connected device that's in progress (shown as a progress pill).
    @Published var deviceTransfer: DeviceTransfer?
    private var deviceTransferTask: Task<Void, Never>?
    /// Device folder whose media gallery should open next (consumed by the App scene).
    @Published var deviceMediaRequest: DeviceMediaRequest?

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
            settings.objectWillChange, sizer.objectWillChange,
            devices.objectWillChange
        ]
        for p in publishers {
            p.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }
        // Moving to another folder leaves the old folder's selection behind.
        engine.$current.map { $0?.id }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.selection = [] }.store(in: &cancellables)
    }

    // MARK: - Lifecycle

    func onAppear() {
        sizer.start(locations: QuickLocations.all)
        BackupSession.removeStaleCopies()
        Self.purgeDevicePreviews()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.personalData.close() }
            Self.purgeDevicePreviews()
        }
        #if DEBUG
        if CommandLine.arguments.contains("--sample-device") { devices.showSample() } else { devices.start() }
        if let i = CommandLine.arguments.firstIndex(of: "--appearance"), i + 1 < CommandLine.arguments.count {
            NSApp.appearance = NSAppearance(named: CommandLine.arguments[i + 1] == "light" ? .aqua : .darkAqua)
        }
        if CommandLine.arguments.contains("--sample-home") { fdaBannerDismissed = true }
        #else
        devices.start()
        #endif
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
        if args.contains("--device") {
            let tab = args.firstIndex(of: "--device-tab").flatMap { i in i + 1 < args.count ? DeviceTab.allCases.first { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) } : nil }
            Task { @MainActor in
                for _ in 0..<100 {
                    if let d = devices.devices.first(where: { $0.isReady }) {
                        select(device: d)
                        if let tab { d.tab = tab }
                        if let i = args.firstIndex(of: "--device-photo-source"), i + 1 < args.count { d.photoSourceFilter = args[i + 1] }
                        if let i = args.firstIndex(of: "--device-path"), i + 1 < args.count {
                            let path = args[i + 1]
                            if path.hasPrefix("app:"), let id = path.split(separator: ":").dropFirst().first.map(String.init) {
                                d.showInFiles("/Documents", domain: .appDocuments(id))   // e.g. app:com.gopro.GoPro
                            } else {
                                d.filesPath = path
                            }
                        }
                        if let i = args.firstIndex(of: "--device-media"), i + 1 < args.count {
                            let path = args[i + 1]
                            let waitForWalk = args.contains("--device-media-after-walk")
                            Task { @MainActor in
                                while !d.appsLoaded || (waitForWalk && !d.allMediaLoaded) { try? await Task.sleep(nanoseconds: 300_000_000) }
                                showMedia(on: d, path: path)
                            }
                        }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 200_000_000)
                }
            }
        }
        #if DEBUG
        if args.contains("--dump-layout") {
            // Writes every window's view frames to <tmp>/diskscout-layout.txt after 7 s. A column
            // whose content asks for more room than the window has shows up here as a frame far
            // taller than the window (see `layoutContained`).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 7_000_000_000)
                var out = ""
                func walk(_ v: NSView, _ depth: Int) {
                    guard depth < 9 else { return }
                    out += String(repeating: "  ", count: depth) + "\(type(of: v)) \(v.frame) hidden=\(v.isHidden) alpha=\(v.alphaValue)\n"
                    for s in v.subviews { walk(s, depth + 1) }
                }
                for w in NSApp.windows {
                    out += "WINDOW \(w.title) frame=\(w.frame) min=\(w.minSize) contentMin=\(w.contentMinSize)\n"
                    if let c = w.contentView?.superview { walk(c, 1) }
                }
                try? out.write(toFile: NSTemporaryDirectory() + "diskscout-layout.txt", atomically: true, encoding: .utf8)
            }
        }
        if ["--personal-data", "--demo-mac-data", "--demo-backup", "--demo-no-backup", "--demo-instagram", "--demo-instagram-html"].contains(where: args.contains) {
            // Invented sample data only: a sample home folder (WhatsApp for Mac, Messages, Notes, calls,
            // Safari), a sample Instagram export, and optionally an encrypted sample backup.
            let tmp = FileManager.default.temporaryDirectory
            let export = tmp.appendingPathComponent("DiskScout-sample-instagram", isDirectory: true)
            if args.contains("--demo-mac-data") || args.contains("--demo-backup") {
                let home = tmp.appendingPathComponent("DiskScout-sample-home", isDirectory: true)
                try? FileManager.default.removeItem(at: home)
                try? BackupFixture.makeMacHome(in: home)
                setenv("DISKSCOUT_MAC_DATA_ROOT", home.path, 1)
                try? FileManager.default.removeItem(at: export)
                try? BackupFixture.makeInstagramExport(in: export)
            }
            let useBackup = args.contains("--demo-backup")
            let noBackup = args.contains("--demo-no-backup")
            if useBackup || noBackup {
                let root = tmp.appendingPathComponent("DiskScout-sample-backups", isDirectory: true)
                try? FileManager.default.removeItem(at: root)
                if noBackup {
                    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                } else {
                    try? BackupFixture.make(in: root, password: "sample-password")
                }
                setenv("DISKSCOUT_BACKUP_ROOT", root.path, 1)
            }
            let section = args.firstIndex(of: "--backup-section").flatMap { i in
                i + 1 < args.count ? BackupSession.Section.allCases.first { $0.rawValue.lowercased().hasPrefix(args[i + 1].lowercased()) } : nil
            }
            let query = args.firstIndex(of: "--backup-search").flatMap { i in i + 1 < args.count ? args[i + 1] : nil }
            Task { @MainActor in
                let s = personalData
                selectPersonalData()
                if useBackup {
                    s.setDevice(nil)
                    await s.switchSource(to: .backup)
                    await s.open(password: "sample-password")
                } else if noBackup {
                    s.setDevice(nil)
                    await s.switchSource(to: .backup)
                } else {
                    await s.start()
                }
                if args.contains("--demo-instagram") { s.openInstagramExport(export) }
                if args.contains("--demo-instagram-html") {
                    // The default format Instagram sends: HTML pages, not JSON.
                    let html = tmp.appendingPathComponent("instagram-jamie.rivera-2026-11-13", isDirectory: true)
                    try? FileManager.default.removeItem(at: html)
                    try? BackupFixture.makeInstagramHTMLExport(in: html)
                    s.openInstagramExport(html)
                }
                if args.contains("--demo-instagram-bad") {
                    // A folder that isn't an export: the setup screen should show why, once.
                    let bad = tmp.appendingPathComponent("DiskScout-sample-not-an-export", isDirectory: true)
                    try? FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
                    s.openInstagramExport(bad)
                }
                if let section { s.section = section; s.load(section) }
                if let i = args.firstIndex(of: "--instagram-export"), i + 1 < args.count {
                    s.openInstagramExport(URL(fileURLWithPath: args[i + 1]))
                }
                if let i = args.firstIndex(of: "--instagram-page") {
                    // Show the export browser, on the first page whose path contains the given text.
                    for _ in 0..<50 where s.conversation(.instagram).value == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    s.instagramPane = .everything
                    let want = i + 1 < args.count ? args[i + 1].lowercased() : ""
                    if !want.isEmpty { s.openExportPage(s.exportPages.first { $0.id.lowercased().contains(want) }?.id) }
                }
                if let service = s.section.service {
                    for _ in 0..<50 where s.conversation(service).value == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    s.selectedThread[service] = s.conversation(service).value?.threads.first?.id
                }
                if s.section == .notes {
                    for _ in 0..<50 where s.notes.value == nil { try? await Task.sleep(nanoseconds: 100_000_000) }
                    s.selectedNote = s.notes.value?.notes.first?.id
                }
                if let query {
                    for sec in BackupSession.Section.allCases { s.load(sec) }
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    searchText = query
                }
            }
        }
        #endif
        #if DEBUG
        if args.contains("--selftest-device") {
            Task { @MainActor in await selfTestDevice() }
        }
        if args.contains("--selftest-video") {
            Task { @MainActor in
                for _ in 0..<50 where devices.devices.first?.isReady != true { try? await Task.sleep(nanoseconds: 200_000_000) }
                guard let d = devices.devices.first, d.isReady else { print("no device"); exit(1) }
                var movs: [DeviceFile] = []
                for folder in (try? await d.listing("/DCIM")) ?? [] where folder.isDirectory && !folder.name.hasPrefix(".") {
                    movs += ((try? await d.listing(folder.path)) ?? []).filter { $0.kind == .video }
                }
                let picks = movs.sorted { $0.size > $1.size }
                let sample = Array(picks.prefix(3)) + Array(picks.dropFirst(picks.count / 2).prefix(3)) + Array(picks.suffix(2))
                let t00 = Date()
                var ok = 0
                for v in sample {
                    let t0 = Date()
                    let img = await d.thumbnail(for: v)
                    if img != nil { ok += 1 }
                    print("[video] \(v.name) \(v.size.bytesString): \(img.map { "\(Int($0.size.width))×\(Int($0.size.height))" } ?? "none") duration \(d.thumbnails.durations[v.id].map { String(format: "%.1fs", $0) } ?? "?") in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s"); fflush(stdout)
                }
                print("[video] \(ok)/\(sample.count) thumbnails in \(String(format: "%.1f", Date().timeIntervalSince(t00)))s"); fflush(stdout)
                exit(0)
            }
        }
        if args.contains("--demo-device-inspect") {
            Task { @MainActor in
                while selectedDevice?.appsLoaded != true { try? await Task.sleep(nanoseconds: 200_000_000) }
                if let d = selectedDevice {
                    let apps = d.sortedApps(filter: "")
                    d.inspectedAppID = (apps.first { $0.tip != nil } ?? apps.first)?.id
                    if args.contains("--demo-device-select") { d.selectedAppIDs = Set(apps.prefix(2).map(\.id)) }
                    switch d.tab {
                    case .photos:
                        while !d.cameraRollLoaded { try? await Task.sleep(nanoseconds: 200_000_000) }
                        let media = d.cameraRoll.filter { $0.kind.isVisualMedia }.sorted { $0.size > $1.size }
                        d.inspectedFile = media.first
                        d.selectedFileIDs = Set(media.prefix(3).map(\.id))
                    case .logs:
                        while d.logFiles.isEmpty { try? await Task.sleep(nanoseconds: 200_000_000) }
                        d.inspectedFile = d.logFiles.first { DeviceLogInfo.parse($0).type == "Crash" } ?? d.logFiles.first
                    case .files, .overview, .backup:
                        break
                    }
                    if args.contains("--demo-device-quicklook"), let f = d.inspectedFile { quickLook(f, on: d) }
                }
            }
        }
        if args.contains("--demo-device-delete") {
            Task { @MainActor in
                while selectedDevice?.appsLoaded != true { try? await Task.sleep(nanoseconds: 200_000_000) }
                // Copies with ids that can't exist on the phone, so even a stray click deletes nothing.
                if let d = selectedDevice {
                    var demo = d.sortedApps(filter: "").prefix(2).map {
                        IOSApp(id: "app.diskscout.demo.\($0.id)", name: $0.name, version: $0.version, appSize: $0.appSize, dataSize: $0.dataSize, fileSharing: $0.fileSharing)
                    }
                    demo.append(IOSApp(id: "app.diskscout.demo.authenticator", name: "Authenticator", version: nil, appSize: 40_000_000, dataSize: 2_000_000, fileSharing: false))
                    requestDeviceDelete(demo, on: d)
                }
            }
        }
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
        guard let plan = trashPlan else { log("FAIL no plan"); exit(1) }
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

    #if DEBUG
    /// Non-destructive end-to-end check against the first connected iPhone: reads storage, apps,
    /// icons, crash logs and media sizes; writes a throwaway folder to the phone's Downloads area and
    /// deletes it again; sends an uninstall for an app id that doesn't exist. Prints and quits.
    private func selfTestDevice() async {
        func log(_ s: String) { print("[device-selftest] \(s)"); fflush(stdout) }
        func fail(_ s: String) -> Never { log("FAIL \(s)"); exit(1) }
        var device: IOSDevice?
        for _ in 0..<50 {
            device = devices.devices.first
            if device?.isReady == true { break }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let d = device else { fail("no device connected (MobileDevice available: \(devices.isAvailable))") }
        guard d.isReady, let info = d.info else { fail("device not ready: \(d.phase)") }
        log("\(info.name) · \(info.model) · \(info.osName) \(info.osVersion) · \(d.link.isWiFi ? "Wi-Fi" : "USB")")
        log("storage: \(info.used.bytesString) used of \(info.capacity.bytesString), \(info.free.bytesString) free")
        guard info.capacity > 0, info.free > 0, info.free < info.capacity else { fail("storage numbers look wrong") }

        await d.refreshApps()
        guard d.appsLoaded, !d.apps.isEmpty else { fail("no apps: \(d.appsError ?? "-")") }
        log("apps: \(d.apps.count), app size \(d.totalAppSize.bytesString), documents & data \(d.totalDataSize.bytesString)")
        for a in d.sortedApps(filter: "").prefix(3) { log("  \(a.name): data \(a.dataSize.bytesString) · \(a.assessment.level)") }

        for _ in 0..<50 where d.icons.count < min(8, d.apps.count) { try? await Task.sleep(nanoseconds: 200_000_000) }
        log("icons loaded: \(d.icons.count)")
        guard !d.icons.isEmpty else { fail("no icons") }

        await d.loadCrashLogs()
        guard let logs = d.crashLogs else { fail("crash logs unreadable") }
        log("crash logs: \(logs.files) files, \(logs.bytes.bytesString)")

        // AFC write + recursive delete on a folder we create ourselves.
        do {
            let afc = try await d.link.perform { try $0.startService("com.apple.afc").afc() }
            let dir = "/Downloads/DiskScout-selftest-\(UUID().uuidString.prefix(8))"
            try afc.createDirectory(dir)
            try afc.createDirectory(dir + "/nested")
            try afc.write(Data(repeating: 7, count: 4096), to: dir + "/nested/probe.bin")
            try afc.write(Data("hello".utf8), to: dir + "/hello.txt")
            guard afc.entry(dir + "/nested/probe.bin")?.size == 4096 else { fail("written file has wrong size") }
            let removed = try afc.removeContents(of: dir)
            try afc.remove(dir)
            guard removed.files == 2, removed.bytes == 4101, afc.entry(dir) == nil else { fail("cleanup left files: \(removed)") }
            log("AFC write + recursive delete OK (\(removed.files) files, \(removed.bytes) bytes)")
        } catch { fail("AFC: \(error.localizedDescription)") }

        // Uninstall path with an id that can't exist: the proxy must answer and the app list must reload.
        let ghost = IOSApp(id: "app.diskscout.selftest.ghost", name: "Ghost", version: nil, appSize: 1, dataSize: 1, fileSharing: false)
        let outcome = await d.uninstall([ghost]) { _, _ in }
        guard d.appsLoaded, outcome.failed.isEmpty, outcome.removed.count == 1 else { fail("uninstall path: \(outcome.failed.map(\.reason))") }
        log("installation_proxy uninstall round-trip OK")

        d.measureMedia()
        while d.isMeasuringMedia || d.media == nil { try? await Task.sleep(nanoseconds: 300_000_000) }
        guard let media = d.media, media.complete else { fail("media walk incomplete") }
        log("media: \(media.total.bytesString) in \(media.files) files")
        for g in media.groups.prefix(4) { log("  \(g.title): \(g.size.bytesString)") }

        // Browsing: camera roll, folder listing, thumbnails, ranged reads, downloads, logs.
        guard d.cameraRollLoaded, !d.cameraRoll.isEmpty else { fail("camera roll empty") }
        let videos = d.cameraRoll.filter { $0.kind == .video }
        log("camera roll: \(d.cameraRoll.count) files, \(videos.count) videos (\(videos.reduce(0) { $0 + $1.size }.bytesString))")
        guard let dcimStat = d.dirStats["/DCIM"], dcimStat.size > 0, d.dirStats["/"]?.size == media.total else { fail("folder sizes don't add up") }
        do {
            let listing = try await d.listing("/DCIM")
            log("listing /DCIM: \(listing.count) entries, e.g. \(listing.prefix(3).map(\.name))")
            guard !listing.isEmpty else { fail("empty listing") }
        } catch { fail("listing: \(error.localizedDescription)") }
        guard let photo = d.cameraRoll.first(where: { $0.kind == .photo && $0.size < 8_000_000 }) else { fail("no photo") }
        var t0 = Date()
        guard let thumb = await d.thumbnail(for: photo) else { fail("photo thumbnail") }
        log("photo thumbnail \(photo.name): \(Int(thumb.size.width))×\(Int(thumb.size.height)) in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
        if let big = videos.max(by: { $0.size < $1.size }) {
            t0 = Date()
            let vt = await d.thumbnail(for: big)
            log("video thumbnail \(big.name) (\(big.size.bytesString)): \(vt != nil ? "OK" : "none"), duration \(d.thumbnails.durations[big.id].map { String(format: "%.1fs", $0) } ?? "?") in \(String(format: "%.2f", Date().timeIntervalSince(t0)))s")
            guard vt != nil else { fail("video thumbnail") }
        }
        do {
            let all = try await d.files.data(photo)
            let part = try await d.files.run(.media) { afc -> Data in
                var out = Data()
                try afc.read(photo.path, from: 1000, length: 5000) { out.append($0); return true }
                return out
            }
            guard all.count == photo.size, part == all.subdata(in: 1000..<6000) else { fail("ranged read mismatch") }
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("diskscout-selftest-\(UUID().uuidString)").appendingPathComponent(photo.name)
            try await d.files.download(photo, to: dest)
            let copied = try Data(contentsOf: dest)
            try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
            guard copied == all else { fail("download mismatch") }
            log("ranged read + download OK (\(all.count) bytes)")
        } catch { fail("read: \(error.localizedDescription)") }
        // Which app saved which photos (read from the Photos database, copy deleted afterwards).
        for _ in 0..<150 where d.photoSourcesState != .ready {
            if case .unavailable(let why) = d.photoSourcesState { fail("photo sources: \(why)") }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard d.photoSourcesState == .ready, !d.photoSources.isEmpty else { fail("photo sources not ready: \(d.photoSourcesState)") }
        let attributed = d.photoSources.reduce(Int64(0)) { $0 + $1.bytes }
        log("saved by: " + d.photoSources.prefix(6).map { "\($0.name) \($0.bytes.bytesString)" }.joined(separator: " · "))
        guard attributed == d.cameraRoll.filter({ $0.kind.isVisualMedia || $0.kind == .photoEdit }).reduce(0, { $0 + $1.size }) else { fail("attribution doesn't add up") }
        let leftovers = ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("DiskScout-photosdb-") }
        guard leftovers.isEmpty else { fail("Photos database copy left behind: \(leftovers)") }

        // Where app data lives: shared groups, iCloud, and a shared Documents folder.
        if let shared = d.apps.first(where: { !d.sharingPartners(of: $0).isEmpty }) {
            log("\(shared.name) shares data with \(d.sharingPartners(of: shared).map(\.name)); leftovers: \(d.leftovers(of: shared))")
        }
        if let app = d.fileSharingApps.first(where: { $0.dataSize > 0 }) {
            let domain = DeviceFileDomain.appDocuments(app.id)
            do {
                let listing = try await d.listing("/Documents", in: domain)
                await d.loadDocStats(domain)
                let stat = d.docStats[domain.key]?["/Documents"]
                log("\(app.name) Documents: \(listing.count) entries, \(stat?.files ?? -1) files, \((stat?.size ?? 0).bytesString)")
                if let f = listing.first(where: { !$0.isDirectory && $0.size > 0 && $0.size < 20_000_000 }) {
                    let dest = FileManager.default.temporaryDirectory.appendingPathComponent("diskscout-doc-\(UUID().uuidString)").appendingPathComponent(f.name)
                    try await d.files.download(f, to: dest)
                    let size = (try FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value
                    try? FileManager.default.removeItem(at: dest.deletingLastPathComponent())
                    guard size == f.size else { fail("app document download size mismatch") }
                    log("copied \(f.name) (\(f.size.bytesString)) from \(app.name)'s Documents")
                }
            } catch { fail("app documents: \(error.localizedDescription)") }
        }

        guard !d.logFiles.isEmpty else { fail("no log list") }
        for f in d.logFiles.prefix(3) {
            let i = DeviceLogInfo.parse(f)
            log("log: \(i.process) · \(i.type) · \(i.date.map { DateFormat.string($0) } ?? "?") · \(f.size.bytesString)")
        }
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
        let hadSheet = trashPlan != nil || mediaTrashPlan != nil || showWelcome
        dismissPlan()
        showWelcome = false
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
        selectedDeviceID = nil
        showingPersonalData = false
        selection = []
        engine.scan(url: url, options: settings.scanOptions)
        if mode == .smartClean { mode = .browse }
    }

    func select(location: SidebarLocation?) {
        selectedLocation = location
        guard let location else { return }
        selectedDeviceID = nil
        showingPersonalData = false
        if location.isSmartClean {
            withAnimation(.snappy) { mode = .smartClean }
            if !cleaner.hasScanned { cleaner.scan() }
        } else {
            scan(url: location.url)
        }
    }

    func rescan() {
        if let d = selectedDevice { d.loadDetails(force: true); return }
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

    /// True while the main area shows something other than the Mac's folders (an iPhone, or
    /// Messages & Notes), where the Mac scan's selection is hidden and must not be acted on.
    var macScanHidden: Bool { selectedDeviceID != nil || showingPersonalData }

    func quickLookSelection() {
        if showingPersonalData { return }
        if let d = selectedDevice {
            if d.tab != .overview, d.tab != .backup, let f = d.inspectedFile, !f.isDirectory { quickLook(f, on: d) }
            return
        }
        guard selectedDeviceID == nil else { return }
        if mode == .smartClean {
            if let item = cleanupInspected { quickLook([item.url]) }
            return
        }
        let urls = nodes(for: selection).map(\.url)
        if !urls.isEmpty { quickLook(urls) }
    }

    func revealSelection() {
        guard !macScanHidden else { return }
        if mode == .smartClean {
            if let item = cleanupInspected { reveal([item.url]) }
            return
        }
        let urls = nodes(for: selection).map(\.url)
        if !urls.isEmpty { reveal(urls) }
        else if let cur = engine.current { reveal([cur.url]) }
    }

    /// Opens the media gallery for a folder (or the folder containing a file).
    func showMedia(in url: URL, isDirectory: Bool = true) {
        let folder = isDirectory ? url : url.deletingLastPathComponent()
        mediaRequest = folder
    }

    func showMediaForSelection() {
        if showingPersonalData { return }
        if let d = selectedDevice {
            // The gallery reads the media area only; an app's Documents or the logs have their own views.
            let f = d.inspectedFile
            guard d.tab == .photos || d.tab == .files, (f?.domain ?? .media) == .media,
                  d.tab == .photos || d.filesDomain == .media else { return }
            let path = f.map { $0.isDirectory ? $0.path : $0.parentPath } ?? (d.tab == .photos ? "/DCIM" : d.filesPath)
            showMedia(on: d, path: path)
            return
        }
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
        let candidates = nodes.map {
            TrashCandidate(url: $0.url, name: $0.name, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isDirectory, action: .moveToTrash, nodeID: $0.id)
        }
        trashPlan = TrashPlan(candidates: candidates)
    }

    func requestTrashSelection() {
        if showingPersonalData { return }
        if let d = selectedDevice {
            // Only the Overview tab's ticked apps; never apps ticked earlier while another tab is showing.
            if d.tab == .overview { requestDeviceDelete(d.selectedApps, on: d) }
            return
        }
        guard selectedDeviceID == nil else { return }
        if mode == .smartClean { requestCleanup(ids: selectedCleanupIDs); return }
        let nodes = nodes(for: selection)
        if !nodes.isEmpty { requestTrash(nodes: nodes) }
    }

    /// Trash flow started from a media gallery window.
    func requestTrash(media items: [MediaItem]) {
        guard !items.isEmpty else { return }
        let candidates = items.map {
            TrashCandidate(url: $0.url, name: $0.name, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isPackage, action: .moveToTrash, nodeID: nil)
        }
        mediaTrashPlan = TrashPlan(candidates: candidates)
    }

    func dismissPlan() {
        trashPlan = nil
        mediaTrashPlan = nil
        deviceDeletePlan = nil
    }

    // MARK: - iPhone & iPad

    var selectedDevice: IOSDevice? { devices.device(id: selectedDeviceID) }

    /// Shows Messages & Notes in the main area.
    func selectPersonalData() {
        selectedDeviceID = nil
        selectedLocation = nil
        showingPersonalData = true
        searchText = ""
        personalData.setDevice(devices.devices.first?.id)
    }

    func select(device: IOSDevice) {
        showingPersonalData = false
        selectedDeviceID = device.id
        selectedLocation = nil
        searchText = ""
        device.loadDetails()
    }

    /// Leaves the device view (for menu commands that only make sense for folder scans).
    func showMode(_ m: ViewMode) {
        selectedDeviceID = nil
        showingPersonalData = false
        withAnimation(.snappyUI) { mode = m }
    }

    func requestDeviceDelete(_ apps: [IOSApp], on device: IOSDevice) {
        guard !apps.isEmpty else { return }
        deviceDeletePlan = DeviceDeletePlan(device: device, apps: apps.sorted { $0.totalSize > $1.totalSize })
    }

    func finishDeviceDelete(_ outcome: DeviceUninstallOutcome, on device: IOSDevice) {
        deviceDeletePlan = nil
        trash.recordFreed(outcome.freed)
        let n = outcome.removed.count
        if outcome.failed.isEmpty {
            show(Toast(title: "Deleted \(n) app\(n == 1 ? "" : "s") from \(device.displayName)",
                       detail: "Freed \(outcome.freed.bytesString). Reinstall from the App Store anytime.", style: .success))
        } else {
            let f = outcome.failed[0]
            show(Toast(title: "\(outcome.failed.count) app\(outcome.failed.count == 1 ? "" : "s") couldn't be deleted",
                       detail: "\(f.app.name): \(f.reason)", style: .error, autoDismiss: false))
        }
    }

    // MARK: Files on a device

    private func deviceCacheURL(for f: DeviceFile, on device: IOSDevice) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskScout/Devices/\(device.id.prefix(12))/\(f.domain.key)", isDirectory: true)
            .appendingPathComponent(String(f.parentPath.dropFirst()), isDirectory: true)
            .appendingPathComponent(f.previewName)
    }

    /// Opens the media gallery for a folder on a connected device.
    func showMedia(on device: IOSDevice, path: String) {
        deviceMediaRequest = DeviceMediaRequest(deviceID: device.id, path: path)
    }

    func quickLook(_ f: DeviceFile, on device: IOSDevice) { quickLook([f], on: device) }

    /// Copies device files to DiskScout's cache (reusing earlier copies) and opens Quick Look.
    func quickLook(_ files: [DeviceFile], on device: IOSDevice) {
        let targets = files.filter { !$0.isDirectory }
        guard !targets.isEmpty, deviceTransfer == nil else { return }
        let urls = targets.map { deviceCacheURL(for: $0, on: device) }
        let missing = zip(targets, urls).filter { f, url in
            ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value != f.size
        }
        if missing.isEmpty {
            QuickLookController.shared.toggle(urls)
            return
        }
        // Previewing copies the files to this Mac first, so keep it bounded and ask before big copies.
        guard targets.count <= 25 else {
            show(Toast(title: "Too many items to preview at once", detail: "Select up to 25, or use Copy to Mac for the rest.", style: .info))
            return
        }
        let bytes = missing.reduce(Int64(0)) { $0 + $1.0.size }
        if bytes > 1_000_000_000 {
            let alert = NSAlert()
            alert.messageText = "Copy \(bytes.bytesString) from the iPhone to preview?"
            alert.informativeText = "Quick Look needs the whole file on this Mac. DiskScout keeps the copy only until you quit."
            alert.addButton(withTitle: "Copy & Preview")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        let destinations = Dictionary(missing.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        deviceTransferTask = Task {
            do {
                try await download(missing.map(\.0), from: device, to: { destinations[$0.id]! },
                                   title: targets.count == 1 ? "Opening \(targets[0].name)" : "Opening \(targets.count) items")
                QuickLookController.shared.preview(urls)
            } catch is CancellationError {
            } catch {
                show(Toast(title: "Couldn't open \(missing[0].0.name)", detail: error.localizedDescription, style: .error, autoDismiss: false))
            }
        }
    }

    /// Asks for a folder, then copies the files there from the device (names kept, never overwriting).
    func copyToMac(_ files: [DeviceFile], from device: IOSDevice) {
        let targets = files.filter { !$0.isDirectory }
        guard !targets.isEmpty, deviceTransfer == nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Copy Here"
        panel.message = "Choose where to copy \(targets.count == 1 ? "“\(targets[0].name)”" : "\(targets.count) files") from \(device.displayName)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        var taken = Set<String>()
        func unique(_ name: String) -> URL {
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            var candidate = name, n = 2
            while taken.contains(candidate.lowercased()) || FileManager.default.fileExists(atPath: folder.appendingPathComponent(candidate).path) {
                candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
                n += 1
            }
            taken.insert(candidate.lowercased())
            return folder.appendingPathComponent(candidate)
        }
        let plan = targets.map { ($0, unique($0.name)) }
        let destinations = Dictionary(plan.map { ($0.0.id, $0.1) }, uniquingKeysWith: { a, _ in a })
        deviceTransferTask = Task {
            do {
                try await download(targets, from: device, to: { destinations[$0.id]! }, title: "Copying from \(device.displayName)")
                let total = targets.reduce(0) { $0 + $1.size }
                show(Toast(title: "Copied \(targets.count) file\(targets.count == 1 ? "" : "s") to \(folder.lastPathComponent)", detail: total.bytesString, style: .success))
                NSWorkspace.shared.activateFileViewerSelecting(plan.map(\.1))
            } catch is CancellationError {
            } catch {
                show(Toast(title: "Copy stopped", detail: error.localizedDescription, style: .error, autoDismiss: false))
            }
        }
    }

    private func download(_ files: [DeviceFile], from device: IOSDevice, to destination: (DeviceFile) -> URL, title: String) async throws {
        let total = files.reduce(0) { $0 + $1.size }
        var before: Int64 = 0
        deviceTransfer = DeviceTransfer(title: title, done: 0, total: total)
        defer { deviceTransfer = nil }
        for f in files {
            let base = before
            try await device.files.download(f, to: destination(f)) { done in
                Task { @MainActor [weak self] in
                    guard var t = self?.deviceTransfer else { return }
                    t.done = base + done
                    if files.count > 1 { t.title = "\(title) · \(f.name)" }
                    self?.deviceTransfer = t
                }
            }
            before += f.size
        }
    }

    /// Stops the copy in progress (a preview or Copy to Mac). The partly copied file is removed.
    func cancelDeviceTransfer() {
        deviceTransferTask?.cancel()
        deviceTransferTask = nil
    }

    /// Previews copied from a device live in the caches folder only for this run.
    nonisolated static func purgeDevicePreviews() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("DiskScout/Devices", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func deleteLogs(_ files: [DeviceFile], on device: IOSDevice) {
        let logs = files.filter { $0.domain == .crashLogs }
        guard !logs.isEmpty else { return }
        Task {
            let r = await device.removeLogs(logs)
            let bytes = r.removed.reduce(0) { $0 + $1.size }
            trash.recordFreed(bytes)
            if r.failures.isEmpty {
                show(Toast(title: "Deleted \(r.removed.count) log\(r.removed.count == 1 ? "" : "s")", detail: "Freed \(bytes.bytesString) on \(device.displayName)", style: .success))
            } else {
                show(Toast(title: "\(r.failures.count) log\(r.failures.count == 1 ? "" : "s") couldn't be deleted", detail: r.failures[0], style: .error, autoDismiss: false))
            }
        }
    }

    func clearCrashLogs(on device: IOSDevice) {
        Task {
            do {
                let result = try await device.clearCrashLogs()
                let r = result.removed
                trash.recordFreed(r.bytes)
                if result.failed == 0 {
                    show(Toast(title: "Cleared \(r.files) crash log\(r.files == 1 ? "" : "s")", detail: "Freed \(r.bytes.bytesString) on \(device.displayName)", style: .success))
                } else {
                    show(Toast(title: "Cleared \(r.files) logs; \(result.failed) couldn't be deleted",
                               detail: "Freed \(r.bytes.bytesString). The iPhone is still using the rest.", style: .info, autoDismiss: false))
                }
            } catch {
                show(Toast(title: "Couldn't clear crash logs", detail: error.localizedDescription, style: .error, autoDismiss: false))
            }
        }
    }

    func requestCleanup(items: [CleanupItem]) {
        guard !items.isEmpty else { return }
        let candidates = items.map {
            TrashCandidate(url: $0.url, name: $0.title, size: $0.size, assessment: $0.assessment,
                           isDirectory: $0.isDirectory, action: $0.action, nodeID: nil)
        }
        trashPlan = TrashPlan(candidates: candidates)
    }

    func requestCleanup(ids: Set<String>) {
        requestCleanup(items: cleaner.items.filter { ids.contains($0.id) })
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
