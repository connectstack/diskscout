import SwiftUI

/// Broad "what kind of thing is this" bucket, used for the disk breakdown bar,
/// treemap colouring, and the inspector.
enum FileCategory: String, CaseIterable, Identifiable, Codable {
    case apps = "Apps"
    case documents = "Documents"
    case photos = "Photos"
    case video = "Video"
    case audio = "Audio"
    case developer = "Developer"
    case caches = "Caches & Logs"
    case archives = "Archives & Installers"
    case system = "System"
    case other = "Other"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .apps:      return Color(red: 0.36, green: 0.58, blue: 1.00)
        case .documents: return Color(red: 1.00, green: 0.76, blue: 0.28)
        case .photos:    return Color(red: 1.00, green: 0.47, blue: 0.58)
        case .video:     return Color(red: 0.74, green: 0.47, blue: 1.00)
        case .audio:     return Color(red: 0.27, green: 0.82, blue: 0.76)
        case .developer: return Color(red: 0.45, green: 0.84, blue: 0.47)
        case .caches:    return Color(red: 0.62, green: 0.67, blue: 0.78)
        case .archives:  return Color(red: 0.96, green: 0.56, blue: 0.27)
        case .system:    return Color(red: 0.52, green: 0.52, blue: 0.62)
        case .other:     return Color(red: 0.72, green: 0.72, blue: 0.78)
        }
    }

    var systemImage: String {
        switch self {
        case .apps:      return "app.fill"
        case .documents: return "doc.text.fill"
        case .photos:    return "photo.fill"
        case .video:     return "film.fill"
        case .audio:     return "music.note"
        case .developer: return "hammer.fill"
        case .caches:    return "memorychip.fill"
        case .archives:  return "shippingbox.fill"
        case .system:    return "gearshape.fill"
        case .other:     return "questionmark.square.fill"
        }
    }

    // MARK: - Classification

    private static let photoExt: Set<String> = ["jpg","jpeg","png","heic","heif","gif","tiff","tif","bmp","webp","raw","cr2","cr3","nef","arw","dng","psd","ai","svg","sketch","fig","icns","ico","avif"]
    private static let videoExt: Set<String> = ["mp4","mov","m4v","mkv","avi","wmv","flv","webm","mts","m2ts","3gp","mpg","mpeg","ts","vob","prores"]
    private static let audioExt: Set<String> = ["mp3","m4a","aac","wav","aiff","aif","flac","ogg","wma","alac","caf","m4b","opus","mid","midi","logicx","band"]
    private static let documentExt: Set<String> = ["pdf","doc","docx","xls","xlsx","ppt","pptx","key","pages","numbers","txt","rtf","rtfd","md","csv","epub","mobi","odt","ods","odp","tex","html","htm","eml","ics","vcf","note"]
    private static let developerExt: Set<String> = ["swift","m","mm","h","hpp","c","cc","cpp","js","mjs","ts","tsx","jsx","py","rb","go","rs","java","kt","kts","php","sh","zsh","json","yaml","yml","toml","xml","plist","lock","xcodeproj","xcworkspace","playground","framework","dylib","a","o","so","class","jar","war","ipa","xcarchive","xctest","bundle","gradle","cmake","proto","sql","sqlite","db","wasm","node","pyc","whl","gem","crate","nupkg","deb","rpm","ko","swiftmodule","swiftdoc","pch","dSYM","dsym"]
    private static let archiveExt: Set<String> = ["zip","tar","gz","tgz","bz2","xz","7z","rar","dmg","pkg","iso","xip","mpkg","img","cdr","sit","sitx","zst","lz4"]
    private static let cacheExt: Set<String> = ["log","crash","ips","tmp","temp","part","crdownload","download","cache","bak","old","swp","dump","core","spin","hang","diag"]

    /// Media classification by extension alone (ignores the path-based rules), used by the
    /// media gallery so a photo inside a cache folder still counts as a photo.
    static func mediaCategory(forExtension rawExt: String) -> FileCategory? {
        let ext = rawExt.lowercased()
        if ext.isEmpty { return nil }
        if photoExt.contains(ext) && !nonVisualPhotoExt.contains(ext) { return .photos }
        if videoExt.contains(ext) { return .video }
        if audioExt.contains(ext) && !nonMediaAudioExt.contains(ext) { return .audio }
        switch ext {
        case "photoslibrary", "aplibrary": return .photos
        case "imovielibrary", "fcpbundle", "tvlibrary": return .video
        case "musiclibrary": return .audio
        default: return nil
        }
    }

    /// Design/source formats that are technically "photos" for the breakdown but not something to browse.
    private static let nonVisualPhotoExt: Set<String> = ["sketch", "fig", "icns", "ico", "ai"]
    private static let nonMediaAudioExt: Set<String> = ["mid", "midi", "logicx", "band"]

    /// Classify a single item. Directories that are not packages are `.other`
    /// (their size is the sum of their files, which are classified individually).
    static func classify(url: URL, isDirectory: Bool, isPackage: Bool) -> FileCategory {
        let path = url.path
        let ext = url.pathExtension.lowercased()

        if isPackage || ext == "app" {
            switch ext {
            case "app": return .apps
            case "photoslibrary", "aplibrary": return .photos
            case "imovielibrary", "fcpbundle", "fcpcache", "tvlibrary": return .video
            case "musiclibrary", "logicx", "band": return .audio
            case "xcodeproj", "xcworkspace", "playground", "framework", "xcarchive", "xctest", "dsym", "bundle": return .developer
            case "pages", "numbers", "key", "rtfd", "scriv": return .documents
            case "pkg", "mpkg": return .archives
            case "prefpane", "qlgenerator", "appex", "kext", "plugin", "component", "saver": return .system
            default: return .other
            }
        }

        if isDirectory { return .other }

        // Path-based signals win over extension.
        if path.hasPrefix("/System/") || path.hasPrefix("/usr/") || path.hasPrefix("/bin/") || path.hasPrefix("/sbin/") || path.hasPrefix("/Library/Apple/") {
            return .system
        }
        if path.contains("/Library/Caches/") || path.contains("/Library/Logs/") || path.contains("/DerivedData/") || path.contains("/private/var/folders/") {
            return .caches
        }
        if path.contains("/node_modules/") || path.contains("/.git/") || path.contains("/Pods/") || path.contains("/.build/") || path.contains("/Library/Developer/") || path.contains("/.gradle/") || path.contains("/.cargo/") || path.contains("/.npm/") || path.contains("/.cocoapods/") {
            return .developer
        }

        if photoExt.contains(ext) { return .photos }
        if videoExt.contains(ext) { return .video }
        if audioExt.contains(ext) { return .audio }
        if documentExt.contains(ext) { return .documents }
        if developerExt.contains(ext) { return .developer }
        if archiveExt.contains(ext) { return .archives }
        if cacheExt.contains(ext) { return .caches }
        if path.contains("/Library/") && !path.contains("/Mobile Documents/") { return .system }
        return .other
    }
}
