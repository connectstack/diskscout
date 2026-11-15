import Foundation
import AppKit
import SwiftUI

// MARK: - Data

struct IOSDeviceInfo: Equatable {
    var name: String
    var model: String
    var productType: String
    var osVersion: String
    var deviceClass: String
    var capacity: Int64
    var free: Int64

    var used: Int64 { max(0, capacity - free) }
    var usedFraction: Double { capacity > 0 ? Double(used) / Double(capacity) : 0 }
    var osName: String { deviceClass == "iPad" ? "iPadOS" : "iOS" }
    var systemImage: String {
        switch deviceClass {
        case "iPad": return "ipad"
        case "iPod": return "ipodtouch"
        default: return "iphone"
        }
    }
}

struct IOSApp: Identifiable, Hashable {
    let id: String          // bundle identifier
    let name: String
    let version: String?
    let appSize: Int64      // the app itself
    let dataSize: Int64     // "Documents & Data" in iPhone Storage
    let fileSharing: Bool   // has a Documents folder visible in Finder / Files
    /// App Group containers: storage shared with the developer's other apps, widgets and extensions.
    let groups: [String]
    /// iCloud containers the app can use (CloudKit or iCloud Drive).
    let iCloudContainers: [String]
    /// Uses iCloud in any form (containers or key-value storage).
    let usesICloud: Bool
    /// Can add photos and videos to the library.
    let canSaveToPhotos: Bool
    let assessment: SafetyAssessment
    let tip: String?

    var totalSize: Int64 { appSize + dataSize }

    init(id: String, name: String, version: String?, appSize: Int64, dataSize: Int64, fileSharing: Bool,
         groups: [String] = [], iCloudContainers: [String] = [], usesICloud: Bool = false, canSaveToPhotos: Bool = false) {
        self.id = id
        self.name = name
        self.version = version
        self.appSize = appSize
        self.dataSize = dataSize
        self.fileSharing = fileSharing
        self.groups = groups
        self.iCloudContainers = iCloudContainers
        self.usesICloud = usesICloud
        self.canSaveToPhotos = canSaveToPhotos
        self.assessment = SafetyClassifier.assessIOSApp(bundleID: id, name: name, dataSize: dataSize, fileSharing: fileSharing)
        self.tip = SafetyClassifier.iosAppTip(bundleID: id)
    }

    static let lookupAttributes = ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
                                   "StaticDiskUsage", "DynamicDiskUsage", "UIFileSharingEnabled", "GroupContainers", "Entitlements",
                                   "NSPhotoLibraryAddUsageDescription", "NSPhotoLibraryUsageDescription"]

    /// Builds an app from one installation_proxy entry.
    init?(bundleID: String, attributes a: [String: Any]) {
        func n(_ k: String) -> Int64 { (a[k] as? NSNumber)?.int64Value ?? 0 }
        let name = (a["CFBundleDisplayName"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (a["CFBundleName"] as? String) ?? bundleID
        let ent = a["Entitlements"] as? [String: Any] ?? [:]
        func strings(_ v: Any?) -> [String] { (v as? [String]) ?? ((v as? [Any])?.compactMap { $0 as? String } ?? []) }
        let groups = (a["GroupContainers"] as? [String: Any]).map { Array($0.keys) } ?? strings(ent["com.apple.security.application-groups"])
        var iCloud: [String] = []
        for k in ["com.apple.developer.icloud-container-identifiers", "com.apple.developer.ubiquity-container-identifiers"] {
            for c in strings(ent[k]) where !iCloud.contains(c) { iCloud.append(c) }
        }
        let usesICloud = !iCloud.isEmpty || ent["com.apple.developer.ubiquity-kvstore-identifier"] != nil
        self.init(id: bundleID, name: name, version: a["CFBundleShortVersionString"] as? String,
                  appSize: max(0, n("StaticDiskUsage")), dataSize: max(0, n("DynamicDiskUsage")),
                  fileSharing: (a["UIFileSharingEnabled"] as? Bool) ?? ((a["UIFileSharingEnabled"] as? NSNumber)?.boolValue ?? false),
                  groups: groups.sorted(), iCloudContainers: iCloud.sorted(), usesICloud: usesICloud,
                  canSaveToPhotos: a["NSPhotoLibraryAddUsageDescription"] != nil || a["NSPhotoLibraryUsageDescription"] != nil)
    }
}

struct DeviceMediaGroup: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let systemImage: String
    let color: Color
    var size: Int64
    var files: Int
}

struct DeviceMediaUsage: Equatable {
    var groups: [DeviceMediaGroup]
    var files: Int
    var complete: Bool
    var total: Int64 { groups.reduce(0) { $0 + $1.size } }

    /// Friendly buckets for the top-level folders of the iPhone's media area.
    static func group(for folder: String) -> (id: String, title: String, detail: String, icon: String, color: Color) {
        switch folder {
        case "DCIM":
            return ("photos", "Photos & videos", "Camera roll originals", "photo.on.rectangle.angled", FileCategory.photos.color)
        case "PhotoData", "MediaAnalysis", "CloudAssets", "Photos":
            return ("photolibrary", "Photos library", "Thumbnails, edits and the library database", "square.stack.3d.up.fill", FileCategory.video.color)
        case "iTunes_Control", "Music", "Podcasts", "Radio":
            return ("music", "Music & podcasts", "Songs and episodes synced or downloaded", "music.note", FileCategory.audio.color)
        case "Books":
            return ("books", "Books", "Books and PDFs", "book.fill", FileCategory.documents.color)
        case "Downloads":
            return ("downloads", "Downloads", "Files left by system downloads", "arrow.down.circle.fill", Color(red: 0.20, green: 0.78, blue: 0.45))
        case "Recordings":
            return ("recordings", "Voice memos", "Older Voice Memos recordings", "waveform", FileCategory.audio.color)
        default:
            return ("other", "Other media", "Smaller system media folders", "folder.fill", FileCategory.other.color)
        }
    }
}

struct DeviceDirStat: Equatable {
    var size: Int64 = 0
    var files: Int = 0
}

enum DeviceTab: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case photos = "Photos & Videos"
    case files = "Files"
    case logs = "Logs"
    case backup = "Messages & Notes"
    var id: String { rawValue }
    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .photos: return "photo.on.rectangle.angled"
        case .files: return "folder"
        case .logs: return "doc.text.magnifyingglass"
        case .backup: return "bubble.left.and.text.bubble.right.fill"
        }
    }
    var searchPrompt: String {
        switch self {
        case .overview: return "Filter apps"
        case .photos: return "Filter photos & videos"
        case .files: return "Filter this folder"
        case .logs: return "Filter logs"
        case .backup: return "Search messages, notes, calls…"
        }
    }
}

struct CrashLogSummary: Equatable {
    var files: Int
    var bytes: Int64
}

struct DeviceUninstallFailure: Identifiable {
    var id: String { app.id }
    let app: IOSApp
    let reason: String
}

struct DeviceUninstallOutcome {
    var removed: [IOSApp] = []
    var failed: [DeviceUninstallFailure] = []
    var freed: Int64 { removed.reduce(0) { $0 + $1.totalSize } }
}

struct DeviceDeletePlan: Identifiable {
    let id = UUID()
    let device: IOSDevice
    let apps: [IOSApp]
    var totalSize: Int64 { apps.reduce(0) { $0 + $1.totalSize } }
    var hasCaution: Bool { apps.contains { $0.assessment.level == .caution } }
    func count(_ level: SafetyLevel) -> Int { apps.filter { $0.assessment.level == level }.count }
}

// MARK: - Device

@MainActor
final class IOSDevice: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case connecting
        case needsTrust(String)
        case ready
        case failed(String)
    }

    enum AppSort: String, CaseIterable, Identifiable {
        case data = "Documents & Data"
        case total = "Total size"
        case app = "App size"
        case name = "Name"
        var id: String { rawValue }
    }

    let id: String
    @Published private(set) var link: DeviceLink
    @Published private(set) var phase: Phase = .connecting
    @Published private(set) var info: IOSDeviceInfo?
    @Published private(set) var apps: [IOSApp] = []
    @Published private(set) var appsLoaded = false
    @Published private(set) var isLoadingApps = false
    @Published private(set) var appsError: String?
    @Published private(set) var icons: [String: NSImage] = [:]
    @Published private(set) var media: DeviceMediaUsage?
    @Published private(set) var isMeasuringMedia = false
    /// The last media walk lost the connection part-way, so sizes and lists may be short.
    @Published private(set) var mediaWalkIncomplete = false
    private var mediaGeneration = 0
    @Published private(set) var crashLogs: CrashLogSummary?
    @Published var sort: AppSort = .data
    @Published var selectedAppIDs: Set<String> = []
    @Published var inspectedAppID: String?

    // Browsing (Photos & Videos, Files, Logs tabs)
    @Published var tab: DeviceTab = .overview
    /// Folder sizes in the media area, keyed by device path ("/" is the whole area).
    @Published private(set) var dirStats: [String: DeviceDirStat] = [:]
    /// Every file in the camera roll (DCIM), available once that folder has been walked.
    @Published private(set) var cameraRoll: [DeviceFile] = []
    @Published private(set) var cameraRollLoaded = false
    /// Every photo, video and audio file in the media area, once the background walk has finished.
    /// Lets "Show Media" on any folder open instantly instead of walking it again.
    private(set) var allMedia: [DeviceFile] = []
    private(set) var allMediaLoaded = false
    @Published private(set) var logFiles: [DeviceFile] = []
    @Published var filesPath: String = "/"
    @Published var inspectedFile: DeviceFile?
    @Published var selectedFileIDs: Set<String> = []

    let files: DeviceFileService
    let thumbnails = DeviceThumbnails()

    // Which app saved each photo (from the Photos database).
    enum PhotoSourcesState: Equatable { case idle, loading, ready, unavailable(String) }
    @Published private(set) var photoSourcesState: PhotoSourcesState = .idle
    @Published private(set) var photoSources: [PhotoSource] = []
    /// Camera-roll file id → photo source id.
    private(set) var photoSourceOfFile: [String: String] = [:]
    /// Filters the Photos & Videos tab to one source.
    @Published var photoSourceFilter: String?

    // Shared Documents folders of file-sharing apps.
    @Published var filesDomain: DeviceFileDomain = .media
    /// Folder sizes inside each app's Documents, keyed by domain then path.
    @Published private(set) var docStats: [String: [String: DeviceDirStat]] = [:]

    private var trustTask: Task<Void, Never>?
    private var mediaTask: Task<Void, Never>?
    private var iconTask: Task<Void, Never>?
    private var detailsTask: Task<Void, Never>?
    private var detailsRequested = false

    init(link: DeviceLink) {
        self.id = link.udid
        self.link = link
        self.files = DeviceFileService(link: link)
    }

    var displayName: String { info?.name ?? "iPhone" }
    var systemImage: String { info?.systemImage ?? "iphone" }
    var isReady: Bool { phase == .ready }

    var totalAppSize: Int64 { apps.reduce(0) { $0 + $1.appSize } }
    var totalDataSize: Int64 { apps.reduce(0) { $0 + $1.dataSize } }

    func sortedApps(filter: String) -> [IOSApp] {
        var list = apps
        if !filter.isEmpty {
            let q = filter.lowercased()
            list = list.filter { $0.name.lowercased().contains(q) || $0.id.lowercased().contains(q) }
        }
        switch sort {
        case .data: list.sort { ($0.dataSize, $0.totalSize) > ($1.dataSize, $1.totalSize) }
        case .total: list.sort { $0.totalSize > $1.totalSize }
        case .app: list.sort { $0.appSize > $1.appSize }
        case .name: list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return list
    }

    var inspectedApp: IOSApp? { inspectedAppID.flatMap { id in apps.first { $0.id == id } } }
    var selectedApps: [IOSApp] { apps.filter { selectedAppIDs.contains($0.id) } }

    // MARK: Connection

    func update(link: DeviceLink) {
        guard link !== self.link else { return }
        self.link = link
        files.setLink(link)
    }

    func disconnected() {
        detailsTask?.cancel()
        trustTask?.cancel()
        mediaTask?.cancel()
        iconTask?.cancel()
    }

    /// Reads name, model and storage. Cheap; runs as soon as the device is plugged in.
    func connect() {
        trustTask?.cancel()
        trustTask = Task { [weak self] in await self?.refreshInfo() }
    }

    func refreshInfo() async {
        do {
            let info = try await link.perform { Self.readInfo($0) }
            self.info = info
            if phase != .ready { phase = .ready }
            if detailsRequested && !appsLoaded { loadDetails() }
        } catch let e as DeviceError where e.needsTrust {
            phase = .needsTrust(e.localizedDescription)
            waitForTrust()
        } catch {
            if info == nil { phase = .failed(error.localizedDescription) }
        }
    }

    /// Shows the Trust prompt on the phone and keeps checking (for up to five minutes) until
    /// the user taps Trust.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { [weak self] in
            for _ in 0..<100 {
                guard let self, !Task.isCancelled else { return }
                if let err = await self.link.requestTrust() {
                    self.phase = .needsTrust(err.localizedDescription)
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                } else {
                    await self.refreshInfo()
                    return
                }
            }
        }
    }

    func retry() {
        phase = .connecting
        connect()
    }

    nonisolated private static func readInfo(_ l: DeviceLink) -> IOSDeviceInfo {
        let du = l.value(nil, domain: "com.apple.disk_usage") as? [String: Any] ?? [:]
        func n(_ k: String) -> Int64 { (du[k] as? NSNumber)?.int64Value ?? 0 }
        let deviceClass = l.value("DeviceClass") as? String ?? "iPhone"
        let productType = l.value("ProductType") as? String ?? deviceClass
        let free = n("AmountDataAvailable") > 0 ? n("AmountDataAvailable") : n("TotalDataAvailable")
        return IOSDeviceInfo(
            name: l.value("DeviceName") as? String ?? deviceClass,
            model: (l.value("MarketingName") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? productType,
            productType: productType,
            osVersion: l.value("ProductVersion") as? String ?? "",
            deviceClass: deviceClass,
            capacity: n("TotalDiskCapacity"),
            free: free
        )
    }

    // MARK: Details (apps, icons, crash logs, media)

    /// Loads everything the device view shows. Called when the device is opened.
    /// The app list comes first: the iPhone needs several seconds to add up each app's data,
    /// and the media walk would only slow that down.
    func loadDetails(force: Bool = false) {
        detailsRequested = true
        guard phase == .ready, detailsTask == nil else { return }
        if appsLoaded && !force { return }
        detailsTask = Task { [weak self] in
            guard let self else { return }
            if force { await self.refreshInfo() }
            await self.refreshApps()
            await self.loadCrashLogs()
            self.detailsTask = nil
            self.measureMedia()
        }
    }

    @discardableResult
    func refreshApps() async -> Bool {
        isLoadingApps = true
        defer { isLoadingApps = false }
        do {
            let raw = try await link.perform { try $0.lookupApps(attributes: IOSApp.lookupAttributes) }
            apps = raw.compactMap { IOSApp(bundleID: $0.key, attributes: $0.value) }
            appsLoaded = true
            appsError = nil
            let ids = Set(apps.map(\.id))
            selectedAppIDs.formIntersection(ids)
            if let i = inspectedAppID, !ids.contains(i) { inspectedAppID = nil }
            loadIcons()
            return true
        } catch {
            appsError = error.localizedDescription
            return false
        }
    }

    private func loadIcons() {
        let missing = apps.map(\.id).filter { icons[$0] == nil }
        guard !missing.isEmpty, iconTask == nil else { return }
        let link = self.link
        iconTask = Task { [weak self] in
            defer { Task { @MainActor [weak self] in self?.iconTask = nil } }
            guard let service = try? await link.perform({ try $0.startService("com.apple.springboardservices") }) else { return }
            let stream = AsyncStream<(String, NSImage)> { cont in
                let flag = CancelFlag()
                cont.onTermination = { _ in flag.cancel() }
                DispatchQueue.global(qos: .utility).async {
                    for id in missing {
                        if flag.isCancelled { break }
                        guard (try? service.send(["command": "getIconPNGData", "bundleId": id])) != nil,
                              let reply = try? service.receive(),
                              let png = reply["pngData"] as? Data,
                              let img = NSImage(data: png) else { continue }
                        cont.yield((id, img))
                    }
                    cont.finish()
                }
            }
            var batch: [String: NSImage] = [:]
            for await (id, img) in stream {
                batch[id] = img
                if batch.count >= 8 {
                    self?.icons.merge(batch) { $1 }
                    batch.removeAll()
                }
            }
            self?.icons.merge(batch) { $1 }
        }
    }

    func loadCrashLogs() async {
        do {
            let list = try await files.run(.crashLogs) { afc -> [DeviceFile] in
                var out: [DeviceFile] = []
                guard afc.walk("/", visit: { e in
                    if !e.isDirectory { out.append(DeviceFile(domain: .crashLogs, entry: e)) }
                    return true
                }) else { throw DeviceError.disconnected }
                return out
            }
            logFiles = list.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            crashLogs = CrashLogSummary(files: list.count, bytes: list.reduce(0) { $0 + $1.size })
        } catch {
            crashLogs = nil
        }
    }

    /// Deletes individual crash or diagnostic reports. Returns what was removed and any failures.
    func removeLogs(_ targets: [DeviceFile]) async -> (removed: [DeviceFile], failures: [String]) {
        var removed: [DeviceFile] = [], failures: [String] = []
        for f in targets where f.domain == .crashLogs {
            do {
                try await files.remove(f)
                removed.append(f)
            } catch {
                failures.append("\(f.name): \(error.localizedDescription)")
            }
        }
        let gone = Set(removed.map(\.id))
        selectedFileIDs.subtract(gone)
        if let i = inspectedFile, gone.contains(i.id) { inspectedFile = nil }
        await loadCrashLogs()
        return (removed, failures)
    }

    /// Lists one folder of the media area for the Files tab.
    func listing(_ path: String) async throws -> [DeviceFile] {
        try await files.list(.media, path)
    }

    func thumbnail(for f: DeviceFile) async -> NSImage? {
        if let img = thumbnails.cached(f) { return img }
        return await thumbnails.thumbnail(for: f, service: files)
    }

    func size(of f: DeviceFile) -> Int64 {
        guard f.isDirectory else { return f.size }
        switch f.domain {
        case .media: return dirStats[f.path]?.size ?? f.size
        case .appDocuments: return docStats[f.domain.key]?[f.path]?.size ?? 0
        case .crashLogs: return f.size
        }
    }

    func stat(of path: String, in domain: DeviceFileDomain) -> DeviceDirStat? {
        domain == .media ? dirStats[path] : docStats[domain.key]?[path]
    }

    /// Lists a folder in any file area (media, or an app's shared Documents).
    func listing(_ path: String, in domain: DeviceFileDomain) async throws -> [DeviceFile] {
        try await files.list(domain, path)
    }

    /// Sizes every folder in an app's shared Documents (small, so one walk is cheap).
    func loadDocStats(_ domain: DeviceFileDomain) async {
        guard domain.appID != nil else { return }
        let root = domain.rootPath
        let stats = try? await files.run(domain) { afc -> [String: DeviceDirStat] in
            var stats: [String: DeviceDirStat] = [root: DeviceDirStat()]
            afc.walk(root) { e in
                guard !e.isDirectory else { return true }
                var p = (e.path as NSString).deletingLastPathComponent
                while p.hasPrefix(root) {
                    stats[p, default: DeviceDirStat()].size += e.size
                    stats[p, default: DeviceDirStat()].files += 1
                    if p == root { break }
                    p = (p as NSString).deletingLastPathComponent
                }
                return true
            }
            return stats
        }
        if let stats { docStats[domain.key] = stats }
    }

    /// Opens the Files tab at a folder (of the media area unless another area is given).
    func showInFiles(_ path: String, domain: DeviceFileDomain = .media, select file: DeviceFile? = nil) {
        filesDomain = domain
        filesPath = path
        inspectedFile = file
        tab = .files
    }

    var fileSharingApps: [IOSApp] { apps.filter(\.fileSharing).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }

    /// Other installed apps that use the same App Group container.
    func appsSharing(_ group: String, besides id: String) -> [IOSApp] {
        apps.filter { $0.id != id && $0.groups.contains(group) }.sorted { $0.name < $1.name }
    }

    func photoSource(forApp id: String) -> PhotoSource? { photoSources.first { $0.id == id } }

    /// Installed apps that share at least one App Group with this one.
    func sharingPartners(of app: IOSApp) -> [IOSApp] {
        var seen = Set<String>()
        return app.groups.flatMap { appsSharing($0, besides: app.id) }.filter { seen.insert($0.id).inserted }
    }

    /// What survives deleting `app` (when the apps in `alsoDeleting` go at the same time), in plain words.
    func leftovers(of app: IOSApp, alsoDeleting: Set<String> = []) -> [String] {
        var out: [String] = []
        if let p = photoSource(forApp: app.id), p.bytes > 0 {
            out.append("\(p.items.formatted()) photo\(p.items == 1 ? "" : "s") and videos it saved (\(p.bytes.bytesString)) stay in Photos")
        }
        let partners = sharingPartners(of: app).filter { !alsoDeleting.contains($0.id) }.map(\.name)
        if !partners.isEmpty {
            let names = ListFormatter.localizedString(byJoining: partners)
            out.append("Data it shares with \(names) stays until \(partners.count == 1 ? "that app is" : "those apps are") deleted too")
        }
        if app.usesICloud {
            out.append("Its iCloud data stays (Settings ▸ your name ▸ iCloud ▸ Manage Storage)")
        }
        return out
    }

    /// Reads which app saved each photo: copies the Photos database off the phone, reads it, and
    /// deletes the copy straight away (it holds private details like locations and faces).
    func loadPhotoSources() {
        guard photoSourcesState != .loading, photoSourcesState != .ready, cameraRollLoaded else { return }
        photoSourcesState = .loading
        let files = self.files
        Task { [weak self] in
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScout-photosdb-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            do {
                for name in ["Photos.sqlite", "Photos.sqlite-wal", "Photos.sqlite-shm"] {
                    let f = DeviceFile(domain: .media, path: "/PhotoData/" + name, size: 0, isDirectory: false, date: nil)
                    do {
                        try await files.download(f, to: dir.appendingPathComponent(name))
                    } catch where name != "Photos.sqlite" {
                        continue   // no write-ahead log right now is fine
                    }
                }
                let path = dir.appendingPathComponent("Photos.sqlite").path
                let assets = try await Task.detached(priority: .utility) { try PhotoSourceReader.read(databaseAt: path) }.value
                self?.applyPhotoSources(assets)
            } catch {
                self?.photoSourcesState = .unavailable(error.localizedDescription)
            }
        }
    }

    private func applyPhotoSources(_ assets: [PhotoSourceReader.Asset]) {
        var byKey: [String: PhotoSourceReader.Asset] = [:]
        for a in assets { byKey[a.key] = a }
        var sources: [String: PhotoSource] = [:]
        var seenKeys: [String: Set<String>] = [:]
        var ofFile: [String: String] = [:]
        let installedNames = Dictionary(apps.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for f in cameraRoll where f.kind.isVisualMedia || f.kind == .photoEdit {
            let key = PhotoSource.assetKey(folder: f.parentPath, baseName: f.baseName)
            let asset = byKey[key]
            var src: PhotoSource
            if let asset, asset.trashed {
                src = sources[PhotoSource.recentlyDeletedID] ?? PhotoSource(id: PhotoSource.recentlyDeletedID, name: "Recently Deleted", systemImage: "trash", isApp: false)
            } else {
                let id = asset?.importer ?? ""
                src = sources[id.isEmpty ? PhotoSource.unknownID : id] ?? PhotoSource.make(bundleID: id, displayName: installedNames[id] ?? asset?.displayName)
            }
            src.bytes += f.size
            if seenKeys[src.id, default: []].insert(key).inserted { src.items += 1 }
            sources[src.id] = src
            ofFile[f.id] = src.id
        }
        photoSourceOfFile = ofFile
        photoSources = sources.values.sorted { $0.bytes > $1.bytes }
        photoSourcesState = .ready
    }

    func photoSourceID(of f: DeviceFile) -> String? { photoSourceOfFile[f.id] }

    /// Deletes every crash and diagnostic report the iPhone keeps for its owner.
    /// Returns what was deleted, and how many reports the iPhone refused to delete.
    func clearCrashLogs() async throws -> (removed: CrashLogSummary, failed: Int) {
        selectedFileIDs = selectedFileIDs.filter { !$0.hasPrefix(DeviceFileDomain.crashLogs.key + ":") }
        if inspectedFile?.domain == .crashLogs { inspectedFile = nil }
        do {
            let result = try await files.run(.crashLogs) { try $0.removeContents(of: "/") }
            await loadCrashLogs()
            return (CrashLogSummary(files: result.files, bytes: result.bytes), result.failed)
        } catch {
            await loadCrashLogs()   // whatever happened, show what's really left
            throw error
        }
    }

    private struct MediaSnapshot {
        var usage: DeviceMediaUsage
        var dirStats: [String: DeviceDirStat]
        var cameraRoll: [DeviceFile]?
        var allMedia: [DeviceFile]?
        var lost = false
    }

    /// Walks the iPhone's media area (photos, music, books…) over AFC: sizes every folder, collects
    /// the camera roll for the Photos & Videos tab, and streams partial totals. The camera roll goes
    /// first so its tab fills as early as possible.
    func measureMedia() {
        mediaTask?.cancel()
        isMeasuringMedia = true
        mediaWalkIncomplete = false
        mediaGeneration += 1
        let generation = mediaGeneration
        let link = self.link
        mediaTask = Task { [weak self] in
            // A cancelled older walk must not clear the flag the newer walk just set.
            defer { if let self, self.mediaGeneration == generation { self.isMeasuringMedia = false } }
            guard let afc = try? await link.perform({ try $0.startService("com.apple.afc").afc() }) else { return }
            let stream = AsyncStream<MediaSnapshot> { cont in
                let flag = CancelFlag()
                cont.onTermination = { _ in flag.cancel() }
                DispatchQueue.global(qos: .utility).async {
                    var groups: [String: DeviceMediaGroup] = [:]
                    var stats: [String: DeviceDirStat] = [:]
                    var roll: [DeviceFile] = []
                    var mediaFiles: [DeviceFile] = []
                    var files = 0
                    var lastYield = Date()
                    var lost = false
                    func snapshot(_ complete: Bool, roll: [DeviceFile]? = nil) -> MediaSnapshot {
                        MediaSnapshot(usage: DeviceMediaUsage(groups: groups.values.filter { $0.size > 0 }.sorted { $0.size > $1.size }, files: files, complete: complete),
                                      dirStats: stats, cameraRoll: roll, allMedia: complete ? mediaFiles : nil)
                    }
                    func count(_ e: AFCClient.Entry) {
                        var p = (e.path as NSString).deletingLastPathComponent
                        while true {
                            if p.isEmpty { p = "/" }
                            stats[p, default: DeviceDirStat()].size += e.size
                            stats[p, default: DeviceDirStat()].files += 1
                            if p == "/" { break }
                            p = (p as NSString).deletingLastPathComponent
                        }
                    }
                    let tops = afc.list("/").sorted { a, b in a == "DCIM" ? true : (b == "DCIM" ? false : a < b) }
                    for top in tops {
                        if flag.isCancelled { break }
                        let g = DeviceMediaUsage.group(for: top)
                        var group = groups[g.id] ?? DeviceMediaGroup(id: g.id, title: g.title, detail: g.detail, systemImage: g.icon, color: g.color, size: 0, files: 0)
                        let path = "/" + top
                        if let e = afc.entry(path), !e.isDirectory {
                            group.size += e.size; group.files += 1; files += 1
                            count(e)
                            let f = DeviceFile(domain: .media, entry: e)
                            if f.mediaKind != nil { mediaFiles.append(f) }
                        } else {
                            let whole = afc.walk(path) { e in
                                if flag.isCancelled { return false }
                                if !e.isDirectory {
                                    group.size += e.size; group.files += 1; files += 1
                                    count(e)
                                    let f = DeviceFile(domain: .media, entry: e)
                                    if top == "DCIM" && !e.path.contains("/.") { roll.append(f) }
                                    if f.mediaKind != nil { mediaFiles.append(f) }
                                }
                                if Date().timeIntervalSince(lastYield) > 0.4 {
                                    groups[g.id] = group
                                    cont.yield(snapshot(false))
                                    lastYield = Date()
                                }
                                return true
                            }
                            if !whole { lost = true }
                        }
                        groups[g.id] = group
                        if lost { break }
                        if top == "DCIM" && !flag.isCancelled { cont.yield(snapshot(false, roll: roll)) }
                    }
                    if lost || tops.isEmpty {
                        // The iPhone stopped answering: publish what we have, but never as complete.
                        var partial = snapshot(false)
                        partial.lost = true
                        cont.yield(partial)
                    } else if !flag.isCancelled {
                        cont.yield(snapshot(true, roll: tops.contains("DCIM") ? nil : []))
                    }
                    cont.finish()
                }
            }
            for await snap in stream {
                guard !Task.isCancelled, let self else { break }
                self.media = snap.usage
                self.dirStats = snap.dirStats
                if snap.lost { self.mediaWalkIncomplete = true }
                if let roll = snap.cameraRoll {
                    self.cameraRoll = roll
                    self.cameraRollLoaded = true
                    // A new camera roll needs its "saved by" attribution worked out again.
                    if self.photoSourcesState != .loading { self.photoSourcesState = .idle }
                    self.loadPhotoSources()
                }
                if let all = snap.allMedia {
                    self.allMedia = all
                    self.allMediaLoaded = true
                }
            }
        }
    }

    // MARK: Uninstall

    /// Removes apps from the iPhone, one at a time, then re-reads the app list to confirm each
    /// one is really gone (the iPhone reports "Complete" even for apps it didn't have).
    func uninstall(_ targets: [IOSApp], progress: @escaping @MainActor (Int, String) -> Void) async -> DeviceUninstallOutcome {
        var outcome = DeviceUninstallOutcome()
        var errors: [String: String] = [:]
        for (i, app) in targets.enumerated() {
            progress(i, app.name)
            do {
                try await link.perform { l in
                    let svc = try l.startService("com.apple.mobile.installation_proxy")
                    try svc.send(["Command": "Uninstall", "ApplicationIdentifier": app.id, "ClientOptions": [String: Any]()])
                    for _ in 0..<600 {
                        let m = try svc.receive()
                        if let err = m["Error"] as? String {
                            throw DeviceError.message((m["ErrorDescription"] as? String) ?? err)
                        }
                        if m["Status"] as? String == "Complete" { return }
                    }
                    throw DeviceError.message("The iPhone took too long to delete the app.")
                }
            } catch {
                errors[app.id] = error.localizedDescription
            }
        }
        progress(targets.count, "")
        // Only a fresh app list can show an app is still there; a stale one would wrongly say "kept".
        let verified = await refreshApps()
        let stillThere = Set(apps.map(\.id))
        for app in targets {
            if let e = errors[app.id] {
                outcome.failed.append(DeviceUninstallFailure(app: app, reason: e))
            } else if verified && stillThere.contains(app.id) {
                outcome.failed.append(DeviceUninstallFailure(app: app, reason: "The iPhone kept this app. It may be managed by a school or company profile, or restricted by Screen Time."))
            } else {
                outcome.removed.append(app)
            }
        }
        selectedAppIDs.subtract(outcome.removed.map(\.id))
        await refreshInfo()
        return outcome
    }
}

// MARK: - Monitor

/// Watches for iPhones and iPads connected over USB (or Wi-Fi, when Finder's "Show this iPhone
/// when on Wi-Fi" is on) and keeps one `IOSDevice` per phone, preferring the USB connection.
@MainActor
final class DeviceMonitor: ObservableObject {
    @Published private(set) var devices: [IOSDevice] = []
    var isAvailable: Bool { api != nil }

    private let api = MobileDeviceAPI.shared
    private var links: [String: [DeviceLink]] = [:]
    private var notification: UnsafeMutableRawPointer?
    private var started = false

    func start() {
        guard let api, !started else { return }
        started = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = api.subscribe(deviceNotificationCallback, 0, 0, ctx, &notification)
    }

    func device(id: String?) -> IOSDevice? {
        guard let id else { return nil }
        return devices.first { $0.id == id }
    }

    fileprivate func attached(_ link: DeviceLink) {
        var list = links[link.udid] ?? []
        list.removeAll { $0.ref == link.ref || $0.isWiFi == link.isWiFi }
        list.append(link)
        links[link.udid] = list
        let best = Self.preferred(list)
        if let d = device(id: link.udid) {
            d.update(link: best)
            if !d.isReady { d.retry() }
        } else {
            let d = IOSDevice(link: best)
            devices.append(d)
            d.connect()
        }
    }

    fileprivate func detached(ref: MDRef, udid: String?, isWiFi: Bool) {
        let key = udid ?? links.first { $0.value.contains { $0.ref == ref } }?.key
        guard let key, var list = links[key] else { return }
        list.removeAll { $0.ref == ref || $0.isWiFi == isWiFi }
        if list.isEmpty {
            links[key] = nil
            if let d = device(id: key) {
                d.disconnected()
                devices.removeAll { $0.id == key }
            }
        } else {
            links[key] = list
            device(id: key)?.update(link: Self.preferred(list))
        }
    }

    private static func preferred(_ list: [DeviceLink]) -> DeviceLink {
        list.first { !$0.isWiFi } ?? list[0]
    }
}

/// C callback from MobileDevice. Delivered on the run loop that subscribed (the main one).
private let deviceNotificationCallback: MobileDeviceAPI.NotificationCallback = { info, ctx in
    guard let ctx, let api = MobileDeviceAPI.shared else { return }
    let ref = info.load(as: MDRef.self)
    let msg = info.load(fromByteOffset: MemoryLayout<UnsafeRawPointer>.size, as: UInt32.self)
    let monitor = Unmanaged<DeviceMonitor>.fromOpaque(ctx).takeUnretainedValue()
    switch msg {
    case 1:
        guard let link = DeviceLink(api: api, ref: ref) else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { monitor.attached(link) } }
    case 2:
        let udid = api.copyDeviceIdentifier(ref)?.takeRetainedValue() as String?
        let isWiFi = api.getInterfaceType(ref) == 2
        let key = Int(bitPattern: ref)
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let ref = MDRef(bitPattern: key) else { return }
                monitor.detached(ref: ref, udid: udid, isWiFi: isWiFi)
            }
        }
    default:
        break
    }
}

#if DEBUG
// MARK: - Sample iPhone

extension DeviceMonitor {
    /// Shows an invented iPhone instead of watching for real ones (`--sample-device`).
    func showSample() {
        if let d = IOSDevice.sample() { devices = [d] }
    }
}

extension IOSDevice {
    /// An invented iPhone for screenshots and UI work: made-up apps, sizes and media. No real device,
    /// and nothing is ever sent to one.
    static func sample() -> IOSDevice? {
        guard let api = MobileDeviceAPI.shared else { return nil }
        let device = IOSDevice(link: DeviceLink(sampleUDID: "00008130-SAMPLE0000000000", api: api))
        device.fillWithSampleData()
        return device
    }

    private func fillWithSampleData() {
        let MB: Int64 = 1_000_000
        info = IOSDeviceInfo(name: "Jamie's iPhone", model: "iPhone 15 Pro", productType: "iPhone16,1", osVersion: "26.1",
                             deviceClass: "iPhone", capacity: 128_000 * MB, free: 21_400 * MB)
        // name, symbol, colours, app size, Documents & Data, shares files, groups, iCloud, saves to Photos
        let list: [(String, String, String, Color, Color, Int64, Int64, Bool, [String], Bool, Bool)] = [
            ("Lumen Camera", "camera.aperture", "com.example.lumen.camera", .purple, .pink, 310, 2_380, false, ["group.com.example.lumen"], true, true),
            ("Chatter", "bubble.left.and.bubble.right.fill", "com.example.chatter", .green, .teal, 280, 1_940, false, ["group.com.example.chatter"], true, true),
            ("StreamBox", "play.rectangle.fill", "com.example.streambox", .red, .orange, 360, 1_310, false, [], false, false),
            ("Beatline", "music.note", "com.example.beatline", .pink, .red, 190, 1_120, false, [], true, false),
            ("Trailhead Maps", "map.fill", "com.example.trailhead", .teal, .blue, 450, 820, false, [], true, false),
            ("Fieldnotes", "note.text", "com.example.fieldnotes", .yellow, .orange, 60, 640, true, [], true, false),
            ("Morning Digest", "newspaper.fill", "com.example.digest", .orange, .red, 140, 610, false, [], false, false),
            ("Puzzle Peaks", "puzzlepiece.fill", "com.example.puzzlepeaks", .mint, .green, 910, 420, false, [], true, false),
            ("Lumen Edit", "slider.horizontal.3", "com.example.lumen.edit", .indigo, .purple, 240, 380, false, ["group.com.example.lumen"], true, true),
            ("Cartwheel", "bag.fill", "com.example.cartwheel", .orange, .yellow, 230, 300, false, [], false, false),
            ("Pocket Wallet", "creditcard.fill", "com.example.pocketwallet", .indigo, .blue, 210, 240, false, [], true, false),
            ("Wayfare", "car.fill", "com.example.wayfare", .gray, .black, 260, 150, false, [], false, false),
            ("Keyring Authenticator", "lock.shield.fill", "com.example.keyring", .blue, .cyan, 40, 12, false, [], true, false),
        ]
        apps = list.map { IOSApp(id: $0.2, name: $0.0, version: "4.2", appSize: $0.5 * MB, dataSize: $0.6 * MB, fileSharing: $0.7,
                                 groups: $0.8, usesICloud: $0.9, canSaveToPhotos: $0.10) }
        icons = Dictionary(uniqueKeysWithValues: list.map { ($0.2, Self.sampleIcon($0.1, $0.3, $0.4)) })
        media = DeviceMediaUsage(groups: [
            DeviceMediaGroup(id: "photos", title: "Photos & videos", detail: "Camera roll originals", systemImage: "photo.on.rectangle.angled", color: FileCategory.photos.color, size: 38_200 * MB, files: 9_842),
            DeviceMediaGroup(id: "photolibrary", title: "Photos library", detail: "Thumbnails, edits and the library database", systemImage: "square.stack.3d.up.fill", color: FileCategory.video.color, size: 6_100 * MB, files: 1_204),
            DeviceMediaGroup(id: "music", title: "Music & podcasts", detail: "Songs and episodes synced or downloaded", systemImage: "music.note", color: FileCategory.audio.color, size: 2_300 * MB, files: 214),
            DeviceMediaGroup(id: "downloads", title: "Downloads", detail: "Files left by system downloads", systemImage: "arrow.down.circle.fill", color: Color(red: 0.20, green: 0.78, blue: 0.45), size: 410 * MB, files: 18),
            DeviceMediaGroup(id: "other", title: "Other media", detail: "Smaller system media folders", systemImage: "folder.fill", color: FileCategory.other.color, size: 820 * MB, files: 6),
        ], files: 11_284, complete: true)
        crashLogs = CrashLogSummary(files: 86, bytes: 6 * MB)
        photoSources = [
            PhotoSource(id: "com.example.lumen.camera", name: "Lumen Camera", systemImage: "app.fill", isApp: true, items: 1_284, bytes: 4_600 * MB),
            PhotoSource(id: "com.example.chatter", name: "Chatter", systemImage: "app.fill", isApp: true, items: 2_931, bytes: 3_100 * MB),
            PhotoSource(id: "com.example.lumen.edit", name: "Lumen Edit", systemImage: "app.fill", isApp: true, items: 212, bytes: 640 * MB),
        ]
        photoSourcesState = .ready
        appsLoaded = true
        phase = .ready
    }

    /// A simple app icon: a gradient square with a symbol.
    private static func sampleIcon(_ symbol: String, _ top: Color, _ bottom: Color) -> NSImage {
        let size = CGSize(width: 120, height: 120)
        return NSImage(size: size, flipped: false) { rect in
            let path = NSBezierPath(roundedRect: rect, xRadius: 27, yRadius: 27)
            NSGradient(starting: NSColor(top), ending: NSColor(bottom))?.draw(in: path, angle: -90)
            let config = NSImage.SymbolConfiguration(pointSize: 54, weight: .semibold).applying(.init(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let g = glyph.size
                glyph.draw(in: CGRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
            }
            return true
        }
    }
}
#endif
