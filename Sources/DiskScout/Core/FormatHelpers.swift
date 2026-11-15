import Foundation
import SwiftUI

/// Where the user's home folder is. Debug builds can swap in an invented one: `--sample-home`
/// builds a sample home with made-up caches, projects and photos, and `DISKSCOUT_HOME=<folder>`
/// points at any folder. Screenshots and UI work then never show anyone's real files.
enum AppPaths {
    static let home: URL = {
        #if DEBUG
        if CommandLine.arguments.contains("--sample-home") { return SampleHome.prepare() }
        if let path = ProcessInfo.processInfo.environment["DISKSCOUT_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        #endif
        return FileManager.default.homeDirectoryForCurrentUser
    }()

    /// True when debug builds are using an invented home instead of the real one.
    static var isSample: Bool { home.standardizedFileURL != FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL }
}

enum ByteFormat {
    static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()

    static func string(_ bytes: Int64) -> String {
        if bytes <= 0 { return "0 KB" }
        return formatter.string(fromByteCount: bytes)
    }

    /// Splits "12.4 GB" into ("12.4", "GB") for big-number typography.
    static func parts(_ bytes: Int64) -> (number: String, unit: String) {
        let s = string(bytes)
        let comps = s.split(separator: " ")
        if comps.count == 2 { return (String(comps[0]), String(comps[1])) }
        return (s, "")
    }
}

enum DateFormat {
    static let medium: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func relativeString(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return relative.localizedString(for: date, relativeTo: .now)
    }

    static func string(_ date: Date?) -> String {
        guard let date else { return "—" }
        return medium.string(from: date)
    }
}

enum SizeTier {
    case huge, large, medium, small, tiny

    init(_ bytes: Int64) {
        let gb: Int64 = 1_000_000_000
        let mb: Int64 = 1_000_000
        switch bytes {
        case (gb * 5)...: self = .huge
        case gb...:       self = .large
        case (mb * 100)...: self = .medium
        case (mb * 10)...:  self = .small
        default:          self = .tiny
        }
    }

    var color: Color {
        switch self {
        case .huge:   return Color(red: 0.95, green: 0.33, blue: 0.36)
        case .large:  return Color(red: 1.00, green: 0.60, blue: 0.20)
        case .medium: return Color(red: 0.98, green: 0.80, blue: 0.25)
        case .small:  return Color(red: 0.36, green: 0.58, blue: 1.00)
        case .tiny:   return .secondary
        }
    }
}

extension Int64 {
    var bytesString: String { ByteFormat.string(self) }
}
