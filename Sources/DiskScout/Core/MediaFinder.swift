import Foundation
import SwiftUI

/// The three kinds of media the gallery shows.
enum MediaKind: String, CaseIterable, Identifiable, Codable {
    case photos = "Photos"
    case videos = "Videos"
    case audio = "Audio"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .photos: return FileCategory.photos.color
        case .videos: return FileCategory.video.color
        case .audio:  return FileCategory.audio.color
        }
    }

    var systemImage: String {
        switch self {
        case .photos: return "photo.fill"
        case .videos: return "film.fill"
        case .audio:  return "music.note"
        }
    }

    init?(category: FileCategory) {
        switch category {
        case .photos: self = .photos
        case .video:  self = .videos
        case .audio:  self = .audio
        default: return nil
        }
    }
}

/// One media file found somewhere under the gallery's root folder.
struct MediaItem: Identifiable, Hashable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: Int64
    let modified: Date?
    let kind: MediaKind
    let isPackage: Bool
    /// Path of the containing folder, relative to the gallery root ("" for the root itself).
    let relativeFolder: String
    let assessment: SafetyAssessment

    static func == (a: MediaItem, b: MediaItem) -> Bool { a.url == b.url }
    func hash(into hasher: inout Hasher) { hasher.combine(url) }
}

/// Walks a folder tree once and streams every photo, video and audio file it finds,
/// so the user never has to open nested folders one by one.
@MainActor
final class MediaFinder: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var isScanning = false
    @Published private(set) var foldersVisited = 0
    @Published private(set) var truncated = false
    @Published private(set) var unreadable = false
    private(set) var root: URL?

    /// Hard ceiling so a gallery on "/" or a giant Photos export stays responsive.
    nonisolated static let maxItems = 20_000

    private var task: Task<Void, Never>?
    private let cancelFlag = CancelFlag()

    var totalSize: Int64 { items.reduce(0) { $0 + $1.size } }

    func count(of kind: MediaKind) -> Int { items.lazy.filter { $0.kind == kind }.count }
    func size(of kind: MediaKind) -> Int64 { items.lazy.filter { $0.kind == kind }.reduce(0) { $0 + $1.size } }

    func start(root: URL, options: ScanOptions) {
        cancel()
        self.root = root
        items = []
        foldersVisited = 0
        truncated = false
        unreadable = false
        isScanning = true
        cancelFlag.reset()
        let flag = cancelFlag

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = MediaFinder.walk(root: root, options: options, cancelled: { flag.isCancelled }) { batch, folders in
                Task { @MainActor [weak self] in
                    guard let self, self.root == root, !flag.isCancelled else { return }
                    self.items.append(contentsOf: batch)
                    self.foldersVisited = folders
                }
            }
            await MainActor.run { [weak self] in
                guard let self, self.root == root else { return }
                if !flag.isCancelled {
                    self.foldersVisited = result.folders
                    self.truncated = result.truncated
                    self.unreadable = result.unreadable
                }
                self.isScanning = false
            }
        }
    }

    func cancel() {
        cancelFlag.cancel()
        task?.cancel()
        task = nil
        isScanning = false
    }

    /// Drop items whose files are gone (after a trash operation).
    func pruneMissing() {
        let fm = FileManager.default
        items.removeAll { !fm.fileExists(atPath: $0.url.path) }
    }

    func remove(urls: Set<URL>) {
        guard !urls.isEmpty else { return }
        items.removeAll { urls.contains($0.url) }
    }

    // MARK: - Walk (background)

    struct WalkResult {
        var folders = 0
        var truncated = false
        var unreadable = false
    }

    nonisolated private static let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
    ]

    nonisolated static func walk(root: URL, options: ScanOptions, cancelled: () -> Bool,
                                 emit: ([MediaItem], Int) -> Void) -> WalkResult {
        let fm = FileManager.default
        var result = WalkResult()
        result.folders = 1 // the root itself
        var enumOptions: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !options.includeHidden { enumOptions.insert(.skipsHiddenFiles) }

        var unreadable = false
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: enumOptions,
                                             errorHandler: { _, _ in unreadable = true; return true }) else {
            result.unreadable = true
            return result
        }

        // The enumerator may spell paths with "/private" resolved (e.g. /private/var vs /var),
        // so compare everything in normalised form.
        let rootPath = SafetyClassifier.normalize(root.standardizedFileURL.path)
        let excluded = Set(options.excludedPaths.map { SafetyClassifier.normalize($0) })
        var batch: [MediaItem] = []
        var produced = 0
        var lastFlush = Date()

        func flush(force: Bool) {
            guard !batch.isEmpty, force || batch.count >= 150 || Date().timeIntervalSince(lastFlush) > 0.2 else { return }
            emit(batch, result.folders)
            batch.removeAll(keepingCapacity: true)
            lastFlush = Date()
        }

        for case let url as URL in enumerator {
            if cancelled() { break }
            if produced >= maxItems { result.truncated = true; break }
            guard let v = try? url.resourceValues(forKeys: keys) else { continue }
            if v.isSymbolicLink == true { continue }
            if !options.includeHidden && (v.isHidden == true || url.lastPathComponent.hasPrefix(".")) {
                if v.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let path = SafetyClassifier.normalize(url.path)
            if !excluded.isEmpty && excluded.contains(path) { enumerator.skipDescendants(); continue }
            if DiskWalker.skipWhenScanningRoot.contains(path) { enumerator.skipDescendants(); continue }

            let isPackage = v.isPackage ?? false
            let isDir = v.isDirectory ?? false
            if isDir && !isPackage { result.folders += 1; continue }

            let category = FileCategory.mediaCategory(forExtension: url.pathExtension)
            guard let category, let kind = MediaKind(category: category) else { continue }

            let size: Int64
            if isPackage {
                size = DiskWalker.size(of: url, cancelled: cancelled) ?? 0
            } else {
                size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            }

            let parentPath = SafetyClassifier.normalize(url.deletingLastPathComponent().standardizedFileURL.path)
            var rel = parentPath.hasPrefix(rootPath) ? String(parentPath.dropFirst(rootPath.count)) : parentPath
            if rel.hasPrefix("/") { rel.removeFirst() }

            batch.append(MediaItem(url: url, name: url.lastPathComponent, size: size, modified: v.contentModificationDate,
                                   kind: kind, isPackage: isPackage, relativeFolder: rel,
                                   assessment: SafetyClassifier.assess(url: url, isDirectory: isPackage)))
            produced += 1
            flush(force: false)
        }
        flush(force: true)
        result.unreadable = unreadable
        return result
    }
}

/// Tiny thread-safe cancellation token (the walk runs in a detached task).
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    func reset() { lock.lock(); flag = false; lock.unlock() }
}
