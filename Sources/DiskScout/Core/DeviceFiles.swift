import Foundation
import AppKit
import AVFoundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Files on a connected device

/// The file areas iOS lets a Mac see over USB.
enum DeviceFileDomain: Hashable, Sendable {
    /// The shared media area: camera roll, Photos' library files, books, music, downloads.
    case media
    /// Crash and diagnostic reports.
    case crashLogs
    /// The Documents folder of an app that shares files with the Mac (UIFileSharingEnabled).
    /// App Store apps' other folders are off limits to every Mac app since iOS 8.3.
    case appDocuments(String)

    /// Stable text form, used in ids and cache paths.
    var key: String {
        switch self {
        case .media: return "media"
        case .crashLogs: return "crashLogs"
        case .appDocuments(let id): return "app-" + id
        }
    }

    /// Where browsing starts.
    var rootPath: String {
        if case .appDocuments = self { return "/Documents" }
        return "/"
    }

    var appID: String? {
        if case .appDocuments(let id) = self { return id }
        return nil
    }

    /// Opens a file connection for this area. Call inside a lockdown session.
    func open(on l: DeviceLink) throws -> AFCClient {
        switch self {
        case .media:
            return try l.startService("com.apple.afc").afc()
        case .crashLogs:
            return try l.startService("com.apple.crashreportcopymobile").afc()
        case .appDocuments(let id):
            // house_arrest hands over an app's Documents folder, then the same connection speaks AFC.
            let svc = try l.startService("com.apple.mobile.house_arrest")
            try svc.send(["Command": "VendDocuments", "Identifier": id])
            let reply = try svc.receive()
            guard reply["Status"] as? String == "Complete" else {
                throw DeviceError.message("The iPhone didn't share this app's files (\(reply["Error"] as? String ?? "no reason given")).")
            }
            return try svc.afc()
        }
    }
}

enum DeviceFileKind: String {
    case folder, photo, screenshot, video, audio, document, log, database, photoEdit, other

    var systemImage: String {
        switch self {
        case .folder: return "folder.fill"
        case .photo: return "photo.fill"
        case .screenshot: return "camera.viewfinder"
        case .video: return "film.fill"
        case .audio: return "music.note"
        case .document: return "doc.richtext.fill"
        case .log: return "doc.text.magnifyingglass"
        case .database: return "cylinder.split.1x2.fill"
        case .photoEdit: return "slider.horizontal.3"
        case .other: return "doc.fill"
        }
    }

    var color: Color {
        switch self {
        case .folder: return Color(red: 0.36, green: 0.58, blue: 1.0)
        case .photo, .screenshot: return FileCategory.photos.color
        case .video: return FileCategory.video.color
        case .audio: return FileCategory.audio.color
        case .document: return FileCategory.documents.color
        case .log: return FileCategory.caches.color
        case .database, .photoEdit, .other: return FileCategory.other.color
        }
    }

    var isVisualMedia: Bool { self == .photo || self == .screenshot || self == .video }
}

struct DeviceFile: Identifiable, Hashable {
    let domain: DeviceFileDomain
    let path: String
    let size: Int64
    let isDirectory: Bool
    let date: Date?

    var id: String { domain.key + ":" + path }
    var name: String { (path as NSString).lastPathComponent }
    var ext: String { (path as NSString).pathExtension.lowercased() }
    var parentPath: String {
        let p = (path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
    var baseName: String { (name as NSString).deletingPathExtension }

    init(domain: DeviceFileDomain, path: String, size: Int64, isDirectory: Bool, date: Date?) {
        self.domain = domain
        self.path = path
        self.size = size
        self.isDirectory = isDirectory
        self.date = date
    }

    init(domain: DeviceFileDomain, entry e: AFCClient.Entry) {
        self.init(domain: domain, path: e.path, size: e.size, isDirectory: e.isDirectory, date: e.date)
    }

    private static let photoExt: Set<String> = ["heic", "heif", "jpg", "jpeg", "png", "gif", "dng", "tif", "tiff", "webp", "bmp"]
    private static let videoExt: Set<String> = ["mov", "mp4", "m4v", "hevc", "3gp"]
    private static let audioExt: Set<String> = ["m4a", "mp3", "aac", "caf", "wav", "aiff", "m4b", "m4p"]
    private static let docExt: Set<String> = ["pdf", "epub", "ibooks", "txt", "rtf"]

    var kind: DeviceFileKind {
        if isDirectory { return .folder }
        if domain == .crashLogs { return .log }
        if Self.photoExt.contains(ext) { return ext == "png" && path.hasPrefix("/DCIM/") ? .screenshot : .photo }
        if Self.videoExt.contains(ext) { return .video }
        if Self.audioExt.contains(ext) { return .audio }
        if Self.docExt.contains(ext) { return .document }
        if ext == "aae" { return .photoEdit }
        if ["sqlite", "sqlite-wal", "sqlite-shm", "db", "plist", "ithmb"].contains(ext) || path.contains(".sqlite") { return .database }
        if ["ips", "log", "crash"].contains(ext) { return .log }
        return .other
    }

    /// Photos, videos and audio, in the Mac gallery's terms.
    var mediaKind: MediaKind? {
        switch kind {
        case .photo, .screenshot: return .photos
        case .video: return .videos
        case .audio: return .audio
        default: return nil
        }
    }

    var assessment: SafetyAssessment {
        if domain.appID != nil { return SafetyClassifier.assessIOSAppDocument(path: path, isDirectory: isDirectory, kind: kind) }
        return SafetyClassifier.assessIOSFile(path: path, isDirectory: isDirectory, isLog: domain == .crashLogs)
    }

    /// Name used for the local copy made for Quick Look (crash reports preview as text).
    var previewName: String { ext == "ips" ? name + ".txt" : name }
}

// MARK: - Media inside a folder

/// Where a device media gallery looks: one folder of one connected device.
struct DeviceMediaRequest: Codable, Hashable {
    let deviceID: String
    let path: String
    var folderName: String { path == "/" ? "iPhone" : (path as NSString).lastPathComponent }
}

/// Walks a folder on the device once, however deep, and streams every photo, video and audio
/// file it finds (the iPhone counterpart of `MediaFinder`). It uses its own AFC connection so
/// thumbnails keep loading while it walks.
@MainActor
final class DeviceMediaFinder: ObservableObject {
    @Published private(set) var items: [DeviceFile] = []
    @Published private(set) var isScanning = false
    @Published private(set) var foldersVisited = 0
    @Published private(set) var truncated = false
    @Published private(set) var error: String?

    nonisolated static let maxItems = 20_000

    private var task: Task<Void, Never>?
    private var flag = CancelFlag()

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }
    func count(of kind: MediaKind) -> Int { items.lazy.filter { $0.mediaKind == kind }.count }
    func size(of kind: MediaKind) -> Int64 { items.lazy.filter { $0.mediaKind == kind }.reduce(0) { $0 + $1.size } }

    func start(device: IOSDevice, root: String) {
        cancel()
        items = []
        foldersVisited = 0
        truncated = false
        error = nil
        // The device view's background walk already saw every file: answer from it instantly.
        if device.allMediaLoaded {
            let prefix = root == "/" ? "/" : root + "/"
            let found = device.allMedia.filter { $0.path.hasPrefix(prefix) }
            truncated = found.count > Self.maxItems
            items = Array(found.prefix(Self.maxItems))
            foldersVisited = max(1, device.dirStats.keys.filter { $0 == root || $0.hasPrefix(prefix) }.count)
            return
        }
        isScanning = true
        let flag = CancelFlag()
        self.flag = flag
        let link = device.link
        task = Task { [weak self] in
            defer { if self?.flag === flag { self?.isScanning = false } }
            let afc: AFCClient
            do {
                afc = try await link.perform { try $0.startService("com.apple.afc").afc() }
            } catch {
                self?.error = error.localizedDescription
                return
            }
            struct Batch { var files: [DeviceFile]; var folders: Int; var truncated: Bool; var lost = false }
            let stream = AsyncStream<Batch> { cont in
                // Only a cancelled listener stops the walk; a normal finish must not, or the last
                // batch would be thrown away.
                cont.onTermination = { reason in if case .cancelled = reason { flag.cancel() } }
                DispatchQueue.global(qos: .userInitiated).async {
                    var batch: [DeviceFile] = []
                    var folders = 1, found = 0, truncated = false
                    var last = Date()
                    let whole = afc.walk(root) { e in
                        if flag.isCancelled { return false }
                        if e.isDirectory { folders += 1; return true }
                        let f = DeviceFile(domain: .media, entry: e)
                        guard f.mediaKind != nil else { return true }
                        batch.append(f)
                        found += 1
                        if found >= DeviceMediaFinder.maxItems { truncated = true; return false }
                        if Date().timeIntervalSince(last) > 0.25 {
                            cont.yield(Batch(files: batch, folders: folders, truncated: false))
                            batch = []
                            last = Date()
                        }
                        return true
                    }
                    cont.yield(Batch(files: batch, folders: folders, truncated: truncated, lost: !whole))
                    cont.finish()
                }
            }
            for await b in stream {
                guard let self, self.flag === flag, !flag.isCancelled else { break }
                self.items.append(contentsOf: b.files)
                self.foldersVisited = b.folders
                if b.truncated { self.truncated = true }
                if b.lost { self.error = "The iPhone stopped responding before every folder was read. What's shown may be incomplete." }
            }
        }
    }

    func cancel() {
        flag.cancel()
        task?.cancel()
        task = nil
        isScanning = false
    }
}

// MARK: - Crash & diagnostic reports

struct DeviceLogInfo: Equatable {
    let process: String
    let type: String
    let date: Date?

    private static let stamp = try! NSRegularExpression(pattern: #"-(\d{4})-(\d{2})-(\d{2})-(\d{2})(\d{2})(\d{2})(?:\.\d+)?$"#)

    /// System reports that aren't crashes, by name.
    private static let systemReports: [String: String] = [
        "JetsamEvent": "Low-memory event", "LowBatteryLog": "Battery log", "WiFiLQMMetrics": "Diagnostic report",
        "SiriSearchFeedback": "Diagnostic report", "PushNotification": "Diagnostic report", "ResetCounter": "Diagnostic report",
    ]

    /// Reads the file names iOS uses, e.g. `Instagram-2026-11-10-093012.ips` (a crash),
    /// `com.apple.WebKit.Networking.diskwrites_resource-….ips`, `ExcUserFault_SpringBoard-….0002.ips`.
    static func parse(_ file: DeviceFile) -> DeviceLogInfo {
        var base = file.baseName
        var date: Date? = nil
        let ns = base as NSString
        if let m = stamp.firstMatch(in: base, range: NSRange(location: 0, length: ns.length)) {
            var c = DateComponents()
            c.year = Int(ns.substring(with: m.range(at: 1)))
            c.month = Int(ns.substring(with: m.range(at: 2)))
            c.day = Int(ns.substring(with: m.range(at: 3)))
            c.hour = Int(ns.substring(with: m.range(at: 4)))
            c.minute = Int(ns.substring(with: m.range(at: 5)))
            c.second = Int(ns.substring(with: m.range(at: 6)))
            date = Calendar.current.date(from: c)
            base = ns.substring(to: m.range.location)
        }
        var process = base
        var key: String? = nil
        // The report kind is the last dotted part when it's a known resource key, so process names
        // that contain dots themselves (com.apple.WebKit.Networking) stay whole.
        if let dot = base.lastIndex(of: "."), dot != base.startIndex {
            let tail = String(base[base.index(after: dot)...])
            if tail.contains("_resource") || tail.hasPrefix("stacks") {
                process = String(base[..<dot])
                key = tail
            }
        }
        let type: String
        if process.hasPrefix("ExcUserFault_") {
            process = String(process.dropFirst("ExcUserFault_".count))
            type = "Non-fatal fault"
        } else if process.hasPrefix("panic") {
            type = "System restart"
        } else if process.hasPrefix("Analytics") || process.hasPrefix("log-aggregated") {
            type = "Analytics"
        } else if let t = systemReports[process] {
            type = t
        } else if let k = key {
            switch k {
            case let k where k.hasPrefix("cpu_resource"): type = k.hasSuffix("fatal") ? "Stopped for CPU use" : "Heavy CPU use"
            case let k where k.hasPrefix("diskwrites_resource"): type = "Heavy disk writes"
            case let k where k.hasPrefix("wakeups_resource"): type = "Too many wake-ups"
            case let k where k.hasPrefix("stacks"): type = "System snapshot"
            default: type = k.replacingOccurrences(of: "_", with: " ").capitalized
            }
        } else if ["ips", "crash"].contains(file.ext) {
            type = "Crash"
        } else {
            type = "Diagnostic log"
        }
        if process.isEmpty { process = file.name }
        return DeviceLogInfo(process: process, type: type, date: date ?? file.date)
    }
}

// MARK: - File service

/// Serialises every file operation on a device through one queue (AFC connections aren't
/// thread-safe) and reopens the connection once if the iPhone dropped it.
final class DeviceFileService: @unchecked Sendable {
    private let io = DispatchQueue(label: "DiskScout.device-files", qos: .userInitiated)
    private var link: DeviceLink
    private var clients: [DeviceFileDomain: AFCClient] = [:]

    init(link: DeviceLink) { self.link = link }

    func setLink(_ l: DeviceLink) {
        io.async { self.link = l; self.clients = [:] }
    }

    private func client(_ d: DeviceFileDomain) throws -> AFCClient {
        if let c = clients[d] { return c }
        let l = link
        let c = try l.queue.sync { try l.withSession { try d.open(on: l) } }
        clients[d] = c
        return c
    }

    /// Runs `body` with an open AFC connection. Work that's still queued when the calling task is
    /// cancelled is skipped.
    func run<T>(_ d: DeviceFileDomain, _ body: @escaping (AFCClient) throws -> T) async throws -> T {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                io.async {
                    if flag.isCancelled { cont.resume(throwing: CancellationError()); return }
                    cont.resume(with: Result {
                        do {
                            return try body(try self.client(d))
                        } catch let e as DeviceError {
                            guard case .failed = e else { throw e }
                            self.clients[d] = nil
                            return try body(try self.client(d))
                        }
                    })
                }
            }
        } onCancel: {
            flag.cancel()
        }
    }

    func list(_ d: DeviceFileDomain, _ path: String) async throws -> [DeviceFile] {
        try await run(d) { afc in afc.entries(in: path).map { DeviceFile(domain: d, entry: $0) } }
    }

    func data(_ f: DeviceFile, limit: Int64 = 120_000_000) async throws -> Data {
        try await run(f.domain) { try $0.readAll(f.path, limit: limit) }
    }

    func remove(_ f: DeviceFile) async throws {
        try await run(f.domain) { try $0.remove(f.path) }
    }

    /// Copies a file from the device to `destination`, reporting bytes copied.
    func download(_ f: DeviceFile, to destination: URL, progress: (@Sendable (Int64) -> Void)? = nil) async throws {
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).part")
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let flag = CancelFlag()
        do {
            try await withTaskCancellationHandler {
                try await run(f.domain) { afc in
                    let h = try FileHandle(forWritingTo: tmp)
                    defer { try? h.close() }
                    var done: Int64 = 0
                    var lastReport = Date.distantPast
                    try afc.read(f.path) { chunk in
                        try h.write(contentsOf: chunk)
                        done += Int64(chunk.count)
                        if Date().timeIntervalSince(lastReport) > 0.2 { progress?(done); lastReport = Date() }
                        return !flag.isCancelled
                    }
                    if flag.isCancelled { throw CancellationError() }
                    progress?(done)
                }
            } onCancel: { flag.cancel() }
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: tmp, to: destination)
            if let d = f.date { try? FileManager.default.setAttributes([.creationDate: d, .modificationDate: d], ofItemAtPath: destination.path) }
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}

// MARK: - Thumbnails

/// Makes thumbnails for photos and videos on the device. Photos are read whole (about 50 ms for a
/// typical HEIC over USB); videos are streamed through AVFoundation so only the bytes needed for
/// one frame cross the cable.
@MainActor
final class DeviceThumbnails {
    private let cache = NSCache<NSString, NSImage>()
    private(set) var durations: [String: Double] = [:]
    private var failed: Set<String> = []

    init() { cache.countLimit = 800 }

    func cached(_ f: DeviceFile) -> NSImage? { cache.object(forKey: f.id as NSString) }

    func thumbnail(for f: DeviceFile, service: DeviceFileService, maxPixel: CGFloat = 360) async -> NSImage? {
        if let img = cached(f) { return img }
        guard !failed.contains(f.id), f.kind.isVisualMedia else { return nil }
        let image: NSImage?
        if f.kind == .video {
            let r = await Self.videoFrame(f, service: service, maxPixel: maxPixel)
            if let d = r.duration { durations[f.id] = d }
            image = r.image
        } else {
            guard let data = try? await service.data(f, limit: 80_000_000) else {
                if !Task.isCancelled { failed.insert(f.id) }
                return nil
            }
            image = await Task.detached(priority: .utility) { Self.downsample(data, maxPixel: maxPixel) }.value
        }
        if let image { cache.setObject(image, forKey: f.id as NSString) } else if !Task.isCancelled { failed.insert(f.id) }
        return image
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func videoFrame(_ f: DeviceFile, service: DeviceFileService, maxPixel: CGFloat) async -> (image: NSImage?, duration: Double?) {
        guard let url = try? await videoProxy(f, service: service) else { return (nil, nil) }
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let duration = try? await asset.load(.duration).seconds
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 2, preferredTimescale: 600)
        let cg = try? await gen.image(at: .zero).image
        return (cg.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height) ) }, duration.flatMap { $0.isFinite ? $0 : nil })
    }

    /// Builds a sparse local stand-in for a device video: the file has the real size, but only its
    /// container boxes (ftyp, moov…) and the first few MB of footage are copied over. That's all
    /// AVFoundation needs for the duration and the first frame, so a 2 GB video costs ~15 MB of USB
    /// traffic and no disk space.
    nonisolated static func videoProxy(_ f: DeviceFile, service: DeviceFileService, footage: Int64 = 12_000_000) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DiskScout-video", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(UUID().uuidString).appendingPathExtension(f.ext.isEmpty ? "mov" : f.ext)
        return try await service.run(f.domain) { afc in
            func be(_ d: Data, _ at: Int, _ n: Int) -> UInt64 {
                d[d.startIndex + at ..< d.startIndex + at + n].reduce(0) { $0 << 8 | UInt64($1) }
            }
            var boxes: [(type: String, offset: Int64, size: Int64)] = []
            var pos: Int64 = 0
            while pos + 8 <= f.size && boxes.count < 200 {
                var header = Data()
                try afc.read(f.path, from: pos, length: 16) { header.append($0); return true }
                guard header.count >= 8 else { break }
                var size = Int64(be(header, 0, 4))
                let type = String(decoding: header[header.startIndex + 4 ..< header.startIndex + 8], as: UTF8.self)
                if size == 1, header.count >= 16 {
                    // A 64-bit size. Raw H.264/HEVC streams also start 00 00 00 01, so this can be garbage.
                    guard let big = Int64(exactly: be(header, 8, 8)), big >= 16 else { break }
                    size = big
                } else if size == 0 {
                    size = f.size - pos
                }
                guard size >= 8, size <= f.size - pos else { break }
                boxes.append((type, pos, size))
                pos += size
            }
            guard boxes.contains(where: { $0.type == "moov" }) else { throw DeviceError.message("Not a QuickTime or MP4 file.") }
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            do {
                let h = try FileHandle(forWritingTo: url)
                defer { try? h.close() }
                try h.truncate(atOffset: UInt64(f.size))
                for b in boxes {
                    let length = b.type == "mdat" ? min(b.size, footage) : (b.size <= 64_000_000 ? b.size : 0)
                    guard length > 0 else { continue }
                    try h.seek(toOffset: UInt64(b.offset))
                    try afc.read(f.path, from: b.offset, length: length) { try h.write(contentsOf: $0); return true }
                }
            } catch {
                try? FileManager.default.removeItem(at: url)   // e.g. unplugged part-way
                throw error
            }
            return url
        }
    }
}
