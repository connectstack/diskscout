#if DEBUG
import Foundation

/// An invented home folder for screenshots and UI work (`--sample-home`): caches, Xcode junk,
/// leftovers, installers, a device backup, projects, photos and films, all made up.
///
/// Sizes look real but cost little disk: every file is an APFS clone of a few shared blobs, with
/// its first block rewritten so no two files are duplicates (except the one pair meant to be).
enum SampleHome {
    private static let MB: Int64 = 1_000_000

    static func prepare() -> URL {
        let fm = FileManager.default
        // In ~/Library/Caches rather than the temporary folder: the safety rules rate everything
        // under /private/var as system files, which would make every sample item Protected.
        let caches = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        let home = caches.appendingPathComponent("DiskScout-sample/jamie", isDirectory: true)
        let blobs = caches.appendingPathComponent("DiskScout-sample/blobs", isDirectory: true)
        try? fm.removeItem(at: home)
        try? fm.createDirectory(at: blobs, withIntermediateDirectories: true)
        let bases: [Int64] = [1 * MB, 16 * MB, 128 * MB, 1_000 * MB].map { size in
            let url = blobs.appendingPathComponent("blob-\(size)")
            if (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ Int64($0) }) != size { writeBlob(url, size: size) }
            return size
        }

        func put(_ path: String, _ size: Int64, unique: Bool = true, daysOld: Double = 3) {
            let url = home.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let base = bases.first { $0 >= size } ?? bases.last!
            let source = blobs.appendingPathComponent("blob-\(base)")
            if clonefile(source.path, url.path, 0) != 0 { try? fm.copyItem(at: source, to: url) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            if size < base { try? handle.truncate(atOffset: UInt64(size)) }
            if unique {
                var bytes = [UInt8](repeating: 0, count: Int(min(4096, size)))
                arc4random_buf(&bytes, bytes.count)
                try? handle.seek(toOffset: 0)
                handle.write(Data(bytes))
            }
            try? handle.close()
            let date = Date().addingTimeInterval(-daysOld * 86_400)
            try? fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        /// A folder of `total` bytes, in pieces no bigger than the largest blob.
        func fill(_ folder: String, _ total: Int64, name: String = "data", ext: String = "bin", daysOld: Double = 3) {
            var left = total, i = 1
            while left > 0 {
                let piece = min(left, 1_000 * MB)
                put("\(folder)/\(name)-\(i).\(ext)", piece, daysOld: daysOld)
                left -= piece
                i += 1
            }
        }

        // Trash
        put(".Trash/Old export.mov", 640 * MB, daysOld: 20)
        put(".Trash/Archive.zip", 210 * MB, daysOld: 20)
        // App caches of apps every Mac has, so they show proper names
        fill("Library/Caches/com.apple.Music", 820 * MB, name: "cache")
        fill("Library/Caches/com.apple.podcasts", 460 * MB, name: "cache")
        fill("Library/Caches/com.apple.Maps", 300 * MB, name: "tiles")
        fill("Library/Caches/com.apple.news", 180 * MB, name: "articles")
        fill("Library/Caches/com.apple.TV", 150 * MB, name: "artwork")
        // Browsers
        fill("Library/Caches/Google/Chrome/Default/Cache/Cache_Data", 1_420 * MB)
        fill("Library/Caches/com.apple.Safari", 380 * MB, name: "WebKitCache")
        // Logs
        fill("Library/Logs/DiagnosticReports", 46 * MB, name: "Lighthouse-2026-11-02", ext: "ips")
        fill("Library/Logs/SyncAgent", 140 * MB, name: "sync", ext: "log")
        fill("Library/Logs/Lighthouse", 62 * MB, name: "debug", ext: "log")
        // Xcode and simulators
        fill("Library/Developer/Xcode/DerivedData/Lighthouse-bqkxwzfhxnqvvgcdtrnmdmyvpbtl/Build/Intermediates.noindex", 2_800 * MB, name: "objects")
        fill("Library/Developer/Xcode/DerivedData/Weather-fjdkslaqpwoeirutyghbnvmcxzla/Build/Products", 900 * MB, name: "products")
        fill("Library/Developer/Xcode/iOS DeviceSupport/iPhone16,1 26.0 (23A341)/Symbols", 3_400 * MB, name: "dyld_shared_cache")
        fill("Library/Developer/CoreSimulator/Caches/dyld", 700 * MB, name: "sim")
        // Developer caches
        fill(".npm/_cacache/content-v2/sha512", 1_060 * MB, name: "pack")
        fill("Library/Caches/Homebrew/downloads", 910 * MB, name: "bottle", ext: "tar.gz")
        fill(".gradle/caches/modules-2/files-2.1", 1_640 * MB, name: "bundle", ext: "jar")
        fill("Library/Caches/pip/http", 310 * MB)
        // Leftovers from apps that aren't installed
        fill("Library/Application Support/com.photomagic.PhotoMagic", 780 * MB, name: "Library", ext: "db", daysOld: 300)
        fill("Library/Containers/com.retroarcade.Arcade/Data/Documents", 340 * MB, name: "saves", daysOld: 400)
        put("Library/Preferences/com.photomagic.PhotoMagic.plist", 1 * MB, daysOld: 300)
        // Installers
        put("Downloads/Lighthouse-4.2.dmg", 380 * MB, daysOld: 40)
        put("Downloads/DevTools-15.1.pkg", 990 * MB, daysOld: 60)
        put("Desktop/Old Installer.dmg", 160 * MB, daysOld: 120)
        // Mail attachment copies
        fill("Library/Containers/com.apple.mail/Data/Library/Mail Downloads/7F3A", 190 * MB, name: "Holiday photos", ext: "zip")
        // A Finder backup of the sample iPhone
        let backup = "Library/Application Support/MobileSync/Backup/00008130-SAMPLE0000000000"
        fill(backup, 5_200 * MB, name: "chunk", daysOld: 35)
        let plist: [String: Any] = ["Device Name": "Jamie's iPhone", "Product Name": "iPhone 15 Pro", "Product Version": "26.1",
                                    "Last Backup Date": Date().addingTimeInterval(-35 * 86_400)]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? data.write(to: home.appendingPathComponent("\(backup)/Info.plist"))
        }
        // Other junk
        fill("Library/Saved Application State/com.apple.Preview.savedState", 9 * MB, name: "windows")
        // The person's own files
        fill("Documents/Projects/Lighthouse/Assets", 1_240 * MB, name: "hero", ext: "psd", daysOld: 12)
        put("Documents/Projects/Lighthouse/Design.sketch", 340 * MB, daysOld: 12)
        put("Documents/Thesis/Thesis draft.docx", 12 * MB, daysOld: 200)
        put("Documents/Taxes 2025.pdf", 4 * MB, daysOld: 220)
        fill("Pictures/Photos Library.photoslibrary/originals", 6_400 * MB, name: "IMG", ext: "heic", daysOld: 30)
        put("Pictures/Wallpapers/Dunes.jpg", 18 * MB, daysOld: 90)
        put("Movies/Beach trip 2026.mov", 1_000 * MB, daysOld: 70)
        // The same film twice, for Duplicates.
        if clonefile(home.appendingPathComponent("Movies/Beach trip 2026.mov").path, home.appendingPathComponent("Movies/Beach trip 2026 copy.mov").path, 0) != 0 {
            try? fm.copyItem(at: home.appendingPathComponent("Movies/Beach trip 2026.mov"), to: home.appendingPathComponent("Movies/Beach trip 2026 copy.mov"))
        }
        put("Movies/Screen Recording 2026-10-14.mov", 420 * MB, daysOld: 30)
        fill("Music/Music/Media.localized/Music", 880 * MB, name: "track", ext: "m4a", daysOld: 500)
        put("Desktop/Screenshot 2026-11-01 at 10.02.11.png", 3 * MB, daysOld: 10)
        put("Desktop/Screenshot 2026-11-04 at 18.40.52.png", 4 * MB, daysOld: 7)
        put("Downloads/Course videos.zip", 1_000 * MB, daysOld: 150)
        put("Downloads/Statement-October.pdf", 1 * MB, daysOld: 20)
        try? fm.createDirectory(at: home.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        return home
    }

    private static func writeBlob(_ url: URL, size: Int64) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        var chunk = [UInt8](repeating: 0, count: Int(min(size, MB)))
        arc4random_buf(&chunk, chunk.count)
        let data = Data(chunk)
        var written: Int64 = 0
        while written < size {
            let n = min(Int64(data.count), size - written)
            handle.write(n == data.count ? data : data.prefix(Int(n)))
            written += n
        }
        try? handle.close()
    }
}
#endif
