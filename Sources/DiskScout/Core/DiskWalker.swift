import Foundation

/// Shared, cancellable directory sizing used by the sidebar and Smart Clean.
enum DiskWalker {
    static let resourceKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileSizeKey,
        .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey
    ]

    /// Paths that are never descended into when scanning from `/`.
    static let skipWhenScanningRoot: Set<String> = [
        "/System/Volumes", "/Volumes", "/dev", "/Network", "/.vol", "/cores",
        "/private/var/vm/sleepimage", "/.fseventsd", "/.Spotlight-V100", "/.DocumentRevisions-V100", "/.TemporaryItems", "/.MobileBackups"
    ]

    /// Allocated size of a file or the recursive total of a folder. `nil` if unreadable.
    nonisolated static func size(of url: URL, cancelled: () -> Bool = { false }) -> Int64? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
        if !isDir.boolValue { return fileSize(at: url) }
        if (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true {
            // Packages are sized like folders but we still return a total.
        }
        var readable = false
        let total = walkSum(url: url, fm: fm, readable: &readable, cancelled: cancelled)
        return readable ? total : nil
    }

    nonisolated private static func walkSum(url: URL, fm: FileManager, readable: inout Bool, cancelled: () -> Bool) -> Int64 {
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return 0 }
        guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: []) else {
            return 0
        }
        readable = true
        var total: Int64 = 0
        for child in contents {
            if cancelled() { return total }
            guard let v = try? child.resourceValues(forKeys: resourceKeys) else { continue }
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true {
                var r = false
                total += walkSum(url: child, fm: fm, readable: &r, cancelled: cancelled)
            } else if let s = v.totalFileAllocatedSize ?? v.fileSize {
                total += Int64(s)
            }
        }
        return total
    }

    /// One pass over `root` that records the total size of every path in `targets`
    /// (which must all live under `root`). Unreadable targets are reported separately.
    nonisolated static func sizes(under root: URL, targets: Set<String>, cancelled: () -> Bool = { false }, onTarget: (String, Int64?) -> Void = { _, _ in }) -> (sizes: [String: Int64], unreadable: Set<String>) {
        var sizes: [String: Int64] = [:]
        var unreadable: Set<String> = []
        let fm = FileManager.default
        func walk(_ url: URL) -> Int64 {
            if cancelled() { return 0 }
            let path = url.path
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true { return 0 }
            guard let contents = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: []) else {
                if targets.contains(path) { unreadable.insert(path); onTarget(path, nil) }
                return 0
            }
            var total: Int64 = 0
            for child in contents {
                if cancelled() { break }
                guard let v = try? child.resourceValues(forKeys: resourceKeys) else { continue }
                if v.isSymbolicLink == true { continue }
                if skipWhenScanningRoot.contains(child.path) { continue }
                if v.isDirectory == true {
                    total += walk(child)
                } else if let s = v.totalFileAllocatedSize ?? v.fileSize {
                    total += Int64(s)
                }
            }
            if targets.contains(path) { sizes[path] = total; onTarget(path, total) }
            return total
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue {
            _ = walk(root)
        } else if targets.contains(root.path) {
            if let s = fileSize(at: root) { sizes[root.path] = s } else { unreadable.insert(root.path) }
        }
        return (sizes, unreadable)
    }

    nonisolated static func fileSize(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        if let s = v?.totalFileAllocatedSize { return Int64(s) }
        if let s = v?.fileSize { return Int64(s) }
        return nil
    }

    /// Whether the current process can read a folder that requires Full Disk Access.
    nonisolated static func hasFullDiskAccess() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let probes = [
            home.appendingPathComponent("Library/Safari"),
            home.appendingPathComponent("Library/Mail"),
            home.appendingPathComponent("Library/Messages"),
        ]
        for p in probes {
            if FileManager.default.fileExists(atPath: p.path) {
                if (try? FileManager.default.contentsOfDirectory(atPath: p.path)) != nil { return true }
                return false
            }
        }
        // None of the probe folders exist: nothing to be blocked by.
        return true
    }
}
