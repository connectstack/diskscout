import Foundation
import CryptoKit
import SwiftUI

struct DuplicateGroup: Identifiable {
    let id = UUID()
    let hash: String
    let size: Int64
    let files: [FileNode]
    var wastedSpace: Int64 { size * Int64(max(0, files.count - 1)) }
}

@MainActor
final class DuplicateFinder: ObservableObject {
    @Published var groups: [DuplicateGroup] = []
    @Published var isWorking: Bool = false
    @Published var totalToCheck: Int = 0
    @Published var checked: Int = 0
    @Published var skipped: Int = 0
    @Published var lastScannedRootID: UUID?
    @Published var error: String?

    private var task: Task<Void, Never>?
    var minSize: Int64 = 64 * 1024 // ignore tiny files (configs, icons) unless the user lowers this

    func cancel() {
        task?.cancel()
        isWorking = false
    }

    var totalWasted: Int64 { groups.reduce(0) { $0 + $1.wastedSpace } }

    func find(in root: FileNode, minSize newMinSize: Int64? = nil) {
        cancel()
        if let newMinSize { self.minSize = newMinSize }
        isWorking = true
        groups = []
        checked = 0
        skipped = 0
        error = nil
        lastScannedRootID = root.id

        let allFiles = root.allFiles().filter { $0.size >= minSize }
        totalToCheck = allFiles.count

        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result = Self.findDuplicates(files: allFiles) { progress, skipped in
                Task { @MainActor [weak self] in
                    self?.checked = progress
                    self?.skipped = skipped
                }
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.groups = result.sorted { $0.wastedSpace > $1.wastedSpace }
                self.isWorking = false
            }
        }
    }

    nonisolated private static func findDuplicates(
        files: [FileNode],
        progress: @escaping (Int, Int) -> Void
    ) -> [DuplicateGroup] {
        // Bucket by size first
        var bySize: [Int64: [FileNode]] = [:]
        for f in files { bySize[f.size, default: []].append(f) }
        let candidates = bySize.values.filter { $0.count >= 2 }

        var output: [DuplicateGroup] = []
        var processed = 0
        var skipped = 0

        for bucket in candidates {
            if Task.isCancelled { break }
            // For each size bucket, hash full files
            var byHash: [String: [FileNode]] = [:]
            for node in bucket {
                if Task.isCancelled { break }
                do {
                    let h = try sha256(url: node.url)
                    byHash[h, default: []].append(node)
                } catch {
                    skipped += 1
                }
                processed += 1
                if processed % 5 == 0 || processed == 1 {
                    progress(processed, skipped)
                }
            }
            for (h, group) in byHash where group.count >= 2 {
                output.append(DuplicateGroup(hash: h, size: group[0].size, files: group))
            }
        }
        progress(processed, skipped)
        return output
    }

    nonisolated private static func sha256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var done = false
        while !done {
            try autoreleasepool {
                let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
                if chunk.isEmpty {
                    done = true
                } else {
                    hasher.update(data: chunk)
                }
            }
            if Task.isCancelled { return "" }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
