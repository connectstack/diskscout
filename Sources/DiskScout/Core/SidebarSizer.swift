import Foundation
import SwiftUI

@MainActor
final class SidebarSizer: ObservableObject {
    @Published private(set) var sizes: [URL: Int64] = [:]
    @Published private(set) var inProgress: Set<URL> = []
    @Published private(set) var unreadable: Set<URL> = []

    private var task: Task<Void, Never>?

    func start(locations: [SidebarLocation]) {
        cancel()
        if let info = DiskInfo.forRoot(), let mac = locations.first(where: { $0.url.path == "/" }) {
            sizes[mac.url] = info.used
        }
        let targets = locations.filter { $0.url.path != "/" && !$0.isSmartClean }.map(\.url)
        inProgress = Set(targets)

        // Group targets so each top-level root is walked exactly once
        // (the home folder and everything inside it share a single pass).
        var groups: [URL: Set<String>] = [:]
        let sortedRoots = targets.sorted { $0.path.count < $1.path.count }
        let sampleHome = AppPaths.isSample ? AppPaths.home.path : nil
        for t in targets {
            // A sample home sits inside the real one: size it on its own rather than as part of /Users.
            if let sampleHome, t.path == sampleHome || t.path.hasPrefix(sampleHome + "/") {
                groups[URL(fileURLWithPath: sampleHome), default: []].insert(t.path)
                continue
            }
            let root = sortedRoots.first { t.path == $0.path || t.path.hasPrefix($0.path + "/") } ?? t
            groups[root, default: []].insert(t.path)
        }
        let plan = groups.map { ($0.key, $0.value) }

        task = Task.detached(priority: .utility) { [weak self] in
            await withTaskGroup(of: (Set<String>, [String: Int64], Set<String>).self) { group in
                for (root, paths) in plan {
                    group.addTask {
                        let r = DiskWalker.sizes(under: root, targets: paths, cancelled: { Task.isCancelled }) { path, size in
                            Task { @MainActor [weak self] in self?.applyResult(url: URL(fileURLWithPath: path), result: size) }
                        }
                        return (paths, r.sizes, r.unreadable)
                    }
                }
                for await (paths, sizes, unreadable) in group {
                    await self?.applyGroup(paths: paths, sizes: sizes, unreadable: unreadable)
                }
            }
        }
    }

    private func applyGroup(paths: Set<String>, sizes: [String: Int64], unreadable: Set<String>) {
        for p in paths {
            let url = URL(fileURLWithPath: p)
            inProgress.remove(url)
            if let s = sizes[p] {
                self.sizes[url] = s
                self.unreadable.remove(url)
            } else {
                self.unreadable.insert(url)
            }
        }
    }

    func cancel() {
        task?.cancel()
        inProgress.removeAll()
    }

    func refresh(_ url: URL) {
        if url.path == "/" {
            if let info = DiskInfo.forRoot() { sizes[url] = info.used }
            return
        }
        inProgress.insert(url)
        Task.detached(priority: .utility) { [weak self] in
            let result = DiskWalker.size(of: url, cancelled: { Task.isCancelled })
            await self?.applyResult(url: url, result: result)
        }
    }

    private func applyResult(url: URL, result: Int64?) {
        inProgress.remove(url)
        if let size = result {
            sizes[url] = size
            unreadable.remove(url)
        } else {
            unreadable.insert(url)
        }
    }
}
