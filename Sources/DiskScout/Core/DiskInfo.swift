import Foundation

struct DiskInfo: Equatable {
    let volumeName: String
    let total: Int64
    let free: Int64
    /// Free space including what macOS can purge on demand (what Finder shows).
    let freeForImportantUsage: Int64

    var used: Int64 { max(0, total - freeForImportantUsage) }
    var purgeable: Int64 { max(0, freeForImportantUsage - free) }
    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(1.0, Double(used) / Double(total))
    }

    static func forRoot() -> DiskInfo? {
        forVolume(at: URL(fileURLWithPath: "/"))
    }

    static func forVolume(at url: URL) -> DiskInfo? {
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeNameKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage.map { Int64($0) } ?? free
        let name = values.volumeName ?? "Macintosh HD"
        guard total > 0 else { return nil }
        return DiskInfo(volumeName: name, total: total, free: free, freeForImportantUsage: max(free, important))
    }
}
