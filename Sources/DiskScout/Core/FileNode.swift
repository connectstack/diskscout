import Foundation
import UniformTypeIdentifiers
import AppKit

final class FileNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let isPackage: Bool
    let isHidden: Bool
    var size: Int64
    var children: [FileNode]
    var itemCount: Int
    var modificationDate: Date?
    var accessDate: Date?
    var creationDate: Date?
    weak var parent: FileNode?

    /// Directories that could not be read (permission denied, etc.)
    var unreadable: Bool = false

    init(url: URL, isDirectory: Bool, isPackage: Bool = false, isHidden: Bool = false, size: Int64 = 0) {
        self.url = url
        self.name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        self.isDirectory = isDirectory
        self.isPackage = isPackage
        self.isHidden = isHidden
        self.size = size
        self.children = []
        self.itemCount = isDirectory ? 0 : 1
    }

    static func == (a: FileNode, b: FileNode) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Derived, cached

    private var _assessment: SafetyAssessment?
    var assessment: SafetyAssessment {
        if let a = _assessment { return a }
        let a = SafetyClassifier.assess(url: url, isDirectory: isDirectory)
        _assessment = a
        return a
    }

    private var _category: FileCategory?
    var category: FileCategory {
        if let c = _category { return c }
        let c = FileCategory.classify(url: url, isDirectory: isDirectory, isPackage: isPackage)
        _category = c
        return c
    }

    /// e.g. "PDF document", "Folder", "Application"
    var kindDescription: String {
        if isDirectory && !isPackage { return "Folder" }
        if let type = UTType(filenameExtension: url.pathExtension), let d = type.localizedDescription, !d.isEmpty {
            return d.prefix(1).uppercased() + d.dropFirst()
        }
        let ext = url.pathExtension
        return ext.isEmpty ? "Document" : "\(ext.uppercased()) file"
    }

    var sortedChildren: [FileNode] {
        children.sorted { $0.size > $1.size }
    }

    var mostRecentActivity: Date? {
        [modificationDate, accessDate].compactMap { $0 }.max()
    }

    var depth: Int {
        var d = 0
        var p = parent
        while let c = p { d += 1; p = c.parent }
        return d
    }

    /// All leaf files under this node (packages count as files).
    func allFiles() -> [FileNode] {
        var out: [FileNode] = []
        var stack: [FileNode] = [self]
        while let n = stack.popLast() {
            if n.isDirectory && !n.isPackage {
                stack.append(contentsOf: n.children)
            } else {
                out.append(n)
            }
        }
        return out
    }

    /// Largest files below this node.
    func largestFiles(limit: Int, minSize: Int64 = 0) -> [FileNode] {
        var files = allFiles().filter { $0.size >= minSize }
        files.sort { $0.size > $1.size }
        return Array(files.prefix(limit))
    }

    /// Category breakdown of everything under this node.
    func categoryTotals() -> [FileCategory: Int64] {
        var totals: [FileCategory: Int64] = [:]
        for f in allFiles() where f.size > 0 {
            totals[f.category, default: 0] += f.size
        }
        return totals
    }

    /// Safety breakdown of the direct children (used in the status bar).
    func safetyTotals() -> [SafetyLevel: Int64] {
        var totals: [SafetyLevel: Int64] = [:]
        for c in children where c.size > 0 {
            totals[c.assessment.level, default: 0] += c.size
        }
        return totals
    }

    /// Finder icon (fast, cached by AppKit).
    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}
