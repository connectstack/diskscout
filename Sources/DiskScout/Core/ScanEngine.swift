import Foundation
import SwiftUI
import os

struct ScanOptions {
    var includeHidden: Bool = true
    var excludedPaths: Set<String> = []
}

/// A top-level folder that has finished scanning (streamed to the UI while scanning).
struct DiscoveredItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let size: Int64
    let isDirectory: Bool
}

/// Thread-safe progress accumulator shared by the worker threads.
final class ScanProgress: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: State())
    private struct State {
        var items = 0
        var bytes: Int64 = 0
        var unreadable = 0
        var denied = 0
        var discovered: [DiscoveredItem] = []
        var cancelled = false
        var lastFlush = Date.distantPast
    }
    let onUpdate: @Sendable (_ items: Int, _ bytes: Int64, _ discovered: [DiscoveredItem]) -> Void

    init(onUpdate: @escaping @Sendable (Int, Int64, [DiscoveredItem]) -> Void) {
        self.onUpdate = onUpdate
    }

    var isCancelled: Bool { lock.withLock { $0.cancelled } }
    func cancel() { lock.withLock { $0.cancelled = true } }

    func add(items: Int, bytes: Int64) {
        let flush: (Int, Int64, [DiscoveredItem])? = lock.withLock { s in
            s.items += items
            s.bytes += bytes
            let now = Date()
            if now.timeIntervalSince(s.lastFlush) > 0.12 {
                s.lastFlush = now
                return (s.items, s.bytes, s.discovered)
            }
            return nil
        }
        if let f = flush { onUpdate(f.0, f.1, f.2) }
    }

    func markUnreadable(denied: Bool) {
        lock.withLock { s in
            s.unreadable += 1
            if denied { s.denied += 1 }
        }
    }

    func discovered(_ item: DiscoveredItem) {
        let flush: (Int, Int64, [DiscoveredItem]) = lock.withLock { s in
            s.discovered.append(item)
            s.discovered.sort { $0.size > $1.size }
            if s.discovered.count > 12 { s.discovered.removeLast(s.discovered.count - 12) }
            s.lastFlush = Date()
            return (s.items, s.bytes, s.discovered)
        }
        onUpdate(flush.0, flush.1, flush.2)
    }

    func snapshot() -> (items: Int, bytes: Int64, unreadable: Int, denied: Int) {
        lock.withLock { ($0.items, $0.bytes, $0.unreadable, $0.denied) }
    }
}

@MainActor
final class ScanEngine: ObservableObject {
    @Published var root: FileNode?
    @Published var current: FileNode?
    @Published var path: [FileNode] = []
    @Published var isScanning: Bool = false
    @Published var scannedItems: Int = 0
    @Published var scannedBytes: Int64 = 0
    @Published var discovered: [DiscoveredItem] = []
    @Published var unreadableCount: Int = 0
    @Published var deniedCount: Int = 0
    @Published var lastError: String?
    @Published var elapsed: TimeInterval = 0
    @Published var categoryTotals: [FileCategory: Int64] = [:]
    @Published var scanTarget: URL?

    /// Navigation history for back/forward.
    private var backStack: [FileNode] = []
    private var forwardStack: [FileNode] = []
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    private var scanTask: Task<Void, Never>?
    private var progress: ScanProgress?
    private var startedAt: Date = .now
    private var tickerTask: Task<Void, Never>?

    func cancel() {
        progress?.cancel()
        scanTask?.cancel()
        tickerTask?.cancel()
        isScanning = false
    }

    func scan(url: URL, options: ScanOptions = ScanOptions()) {
        cancel()
        isScanning = true
        scannedItems = 0
        scannedBytes = 0
        discovered = []
        unreadableCount = 0
        deniedCount = 0
        lastError = nil
        elapsed = 0
        startedAt = .now
        root = nil
        current = nil
        path = []
        backStack = []
        forwardStack = []
        categoryTotals = [:]
        scanTarget = url

        tickerTask = Task { [weak self] in
            while !Task.isCancelled, let self, self.isScanning {
                try? await Task.sleep(nanoseconds: 100_000_000)
                self.elapsed = Date().timeIntervalSince(self.startedAt)
            }
        }

        let progress = ScanProgress { items, bytes, discovered in
            Task { @MainActor [weak self] in
                guard let self, self.isScanning else { return }
                self.scannedItems = items
                self.scannedBytes = bytes
                if self.discovered != discovered { self.discovered = discovered }
            }
        }
        self.progress = progress

        scanTask = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.scanSync(url: url, options: options, progress: progress)
            let snap = progress.snapshot()
            let totals: [FileCategory: Int64]
            if case .success(let node) = result { totals = node.categoryTotals() } else { totals = [:] }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard self.progress === progress else { return } // superseded by a newer scan
                self.isScanning = false
                self.tickerTask?.cancel()
                self.elapsed = Date().timeIntervalSince(self.startedAt)
                self.unreadableCount = snap.unreadable
                self.deniedCount = snap.denied
                switch result {
                case .success(let node):
                    self.scannedItems = node.itemCount
                    self.scannedBytes = node.size
                    self.categoryTotals = totals
                    self.root = node
                    self.current = node
                    self.path = [node]
                case .failure(let err):
                    self.lastError = err.localizedDescription
                }
            }
        }
    }

    // MARK: - Navigation

    func enter(_ node: FileNode, recordHistory: Bool = true) {
        guard node.isDirectory, !node.isPackage else { return }
        if recordHistory, let c = current, c.id != node.id {
            backStack.append(c)
            forwardStack.removeAll()
        }
        current = node
        var newPath: [FileNode] = []
        var n: FileNode? = node
        while let c = n {
            newPath.insert(c, at: 0)
            n = c.parent
        }
        path = newPath
    }

    func goUp() {
        guard let parent = current?.parent else { return }
        enter(parent)
    }

    func goBack() {
        guard let prev = backStack.popLast(), let c = current else { return }
        forwardStack.append(c)
        enter(prev, recordHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast(), let c = current else { return }
        backStack.append(c)
        enter(next, recordHistory: false)
    }

    func goTo(_ node: FileNode) { enter(node) }

    /// Find the node for a URL within the scanned tree.
    func node(for url: URL) -> FileNode? {
        guard let root else { return nil }
        let target = url.standardizedFileURL.path
        if root.url.standardizedFileURL.path == target { return root }
        var node = root
        outer: while true {
            for c in node.children {
                let p = c.url.standardizedFileURL.path
                if p == target { return c }
                if target.hasPrefix(p + "/") { node = c; continue outer }
            }
            return nil
        }
    }

    // MARK: - Mutations

    /// Attach an already-built subtree under `parent`, updating ancestor totals.
    func insert(_ node: FileNode, into parent: FileNode) {
        parent.children.removeAll { $0.url.standardizedFileURL.path == node.url.standardizedFileURL.path }
        node.parent = parent
        parent.children.append(node)
        var p: FileNode? = parent
        while let c = p {
            c.size += node.size
            c.itemCount += node.itemCount
            p = c.parent
        }
        for f in node.allFiles() where f.size > 0 {
            categoryTotals[f.category, default: 0] += f.size
        }
        objectWillChange.send()
    }

    func remove(_ node: FileNode) {
        guard let parent = node.parent else {
            if root?.id == node.id { root = nil; current = nil; path = [] }
            return
        }
        parent.children.removeAll { $0.id == node.id }
        var p: FileNode? = parent
        while let c = p {
            c.size -= node.size
            c.itemCount -= node.itemCount
            p = c.parent
        }
        for f in node.allFiles() where f.size > 0 {
            categoryTotals[f.category, default: 0] -= f.size
        }
        // If we were inside the removed subtree, move up.
        if let cur = current {
            var n: FileNode? = cur
            while let c = n {
                if c.id == node.id { enter(parent, recordHistory: false); break }
                n = c.parent
            }
        }
        backStack.removeAll { $0.id == node.id }
        forwardStack.removeAll { $0.id == node.id }
        objectWillChange.send()
    }

    // MARK: - Scanning core (runs off main)

    /// Builds a fully populated subtree for `url` (used when putting items back from the Trash).
    nonisolated static func buildSubtree(url: URL, options: ScanOptions) -> FileNode? {
        let progress = ScanProgress { _, _, _ in }
        if case .success(let node) = scanSync(url: url, options: options, progress: progress) { return node }
        return nil
    }

    nonisolated private static func scanSync(url: URL, options: ScanOptions, progress: ScanProgress) -> Result<FileNode, Error> {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .failure(NSError(domain: "DiskScout", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "That folder doesn't exist any more."]))
        }
        let isPackage = (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false
        let root = FileNode(url: url, isDirectory: isDir.boolValue, isPackage: isPackage)
        root.modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if isDir.boolValue {
            populate(node: root, depth: 0, options: options, isRootScan: url.path == "/", progress: progress)
            if root.unreadable && root.children.isEmpty {
                return .failure(NSError(domain: "DiskScout", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "macOS didn't allow DiskScout to read this folder. Grant Full Disk Access in System Settings ▸ Privacy & Security."]))
            }
        } else {
            root.size = DiskWalker.fileSize(at: url) ?? 0
            progress.add(items: 1, bytes: root.size)
        }
        if progress.isCancelled {
            return .failure(CancellationError())
        }
        return .success(root)
    }

    nonisolated private static let childKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
        .isSymbolicLinkKey, .isPackageKey, .isHiddenKey,
        .contentModificationDateKey, .contentAccessDateKey, .creationDateKey
    ]

    nonisolated private static func populate(node: FileNode, depth: Int, options: ScanOptions, isRootScan: Bool, progress: ScanProgress) {
        if progress.isCancelled { return }
        let fm = FileManager.default
        let url = node.url

        let contents: [URL]
        do {
            contents = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(childKeys),
                                                  options: options.includeHidden ? [] : [.skipsHiddenFiles])
        } catch {
            node.unreadable = true
            let code = (error as NSError).code
            let denied = code == NSFileReadNoPermissionError || code == 257 || code == 1 || code == 13
            progress.markUnreadable(denied: denied)
            return
        }

        var files: [FileNode] = []
        var dirs: [FileNode] = []
        var fileBytes: Int64 = 0

        for child in contents {
            guard let v = try? child.resourceValues(forKeys: childKeys) else { continue }
            if v.isSymbolicLink == true { continue }
            let path = child.path
            if options.excludedPaths.contains(path) { continue }
            if isRootScan, DiskWalker.skipWhenScanningRoot.contains(path) { continue }
            let childIsDir = v.isDirectory ?? false
            let isPackage = v.isPackage ?? false
            let hidden = v.isHidden ?? false

            if childIsDir && !isPackage {
                let n = FileNode(url: child, isDirectory: true, isPackage: false, isHidden: hidden)
                n.parent = node
                n.modificationDate = v.contentModificationDate
                n.accessDate = v.contentAccessDate
                n.creationDate = v.creationDate
                dirs.append(n)
            } else {
                var size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                if childIsDir && isPackage {
                    // Packages (.app, .photoslibrary…) are opaque: size them in one go.
                    size = DiskWalker.size(of: child, cancelled: { progress.isCancelled }) ?? 0
                }
                let n = FileNode(url: child, isDirectory: childIsDir, isPackage: isPackage, isHidden: hidden, size: size)
                n.parent = node
                n.modificationDate = v.contentModificationDate
                n.accessDate = v.contentAccessDate
                n.creationDate = v.creationDate
                files.append(n)
                fileBytes += size
            }
        }
        progress.add(items: files.count, bytes: fileBytes)

        // Fan out across cores near the top of the tree; go sequential deeper down.
        if depth < 2 && dirs.count > 1 {
            DispatchQueue.concurrentPerform(iterations: dirs.count) { i in
                let d = dirs[i]
                populate(node: d, depth: depth + 1, options: options, isRootScan: isRootScan, progress: progress)
                if depth == 0 {
                    progress.discovered(DiscoveredItem(id: d.id, name: d.name, size: d.size, isDirectory: true))
                }
            }
        } else {
            for d in dirs {
                if progress.isCancelled { break }
                populate(node: d, depth: depth + 1, options: options, isRootScan: isRootScan, progress: progress)
                if depth == 0 {
                    progress.discovered(DiscoveredItem(id: d.id, name: d.name, size: d.size, isDirectory: true))
                }
            }
        }

        var total = fileBytes
        var count = files.count
        for d in dirs {
            total += d.size
            count += d.itemCount
        }
        node.children = files + dirs
        node.size = total
        node.itemCount = count
    }
}
