import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("showHiddenFiles") var showHiddenFiles: Bool = true
    @AppStorage("confirmSafeDeletes") var confirmSafeDeletes: Bool = true
    @AppStorage("reduceMotion") var reduceMotion: Bool = false
    @AppStorage("treemapColorMode") var treemapColorMode: String = TreemapColorMode.safety.rawValue
    @AppStorage("hasSeenWelcome") var hasSeenWelcome: Bool = false
    @AppStorage("duplicateMinSizeKB") var duplicateMinSizeKB: Int = 64
    @AppStorage("excludedPathsData") private var excludedPathsData: Data = Data()
    @AppStorage("defaultMode") var defaultMode: String = ViewMode.smartClean.rawValue

    var excludedPaths: [String] {
        get { (try? JSONDecoder().decode([String].self, from: excludedPathsData)) ?? [] }
        set { excludedPathsData = (try? JSONEncoder().encode(newValue)) ?? Data(); objectWillChange.send() }
    }

    var scanOptions: ScanOptions {
        ScanOptions(includeHidden: showHiddenFiles, excludedPaths: Set(excludedPaths))
    }

    var treemapColors: TreemapColorMode {
        get { TreemapColorMode(rawValue: treemapColorMode) ?? .safety }
        set { treemapColorMode = newValue.rawValue }
    }
}

enum TreemapColorMode: String, CaseIterable, Identifiable {
    case safety = "Safety"
    case category = "Type"
    case size = "Size"
    var id: String { rawValue }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case smartClean = "Smart Clean"
    case browse = "Browse"
    case treemap = "Treemap"
    case duplicates = "Duplicates"
    case finder = "Large & Old"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .smartClean: return "sparkles"
        case .browse: return "list.bullet"
        case .treemap: return "rectangle.split.3x3"
        case .duplicates: return "doc.on.doc"
        case .finder: return "clock.arrow.circlepath"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .smartClean: return "1"
        case .browse: return "2"
        case .treemap: return "3"
        case .duplicates: return "4"
        case .finder: return "5"
        }
    }

    var needsScan: Bool { self != .smartClean }
}
