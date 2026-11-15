import Foundation

/// One device backup made by Finder (or iTunes) on this Mac.
struct IOSBackupInfo: Identifiable, Hashable {
    let id: String              // folder name, normally the device's UDID
    let url: URL
    let deviceName: String
    let productType: String?
    let productVersion: String?
    let date: Date?
    let isEncrypted: Bool
    /// False while a backup is still being written (or was interrupted).
    let isComplete: Bool
    let udid: String

    static func read(at url: URL) -> IOSBackupInfo? {
        func plist(_ name: String) -> [String: Any]? {
            guard let d = try? Data(contentsOf: url.appendingPathComponent(name)) else { return nil }
            return try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any]
        }
        guard let info = plist("Info.plist") ?? plist("Manifest.plist") else { return nil }
        let manifest = plist("Manifest.plist") ?? [:]
        let status = plist("Status.plist") ?? [:]
        let lockdown = manifest["Lockdown"] as? [String: Any] ?? [:]
        let udid = (info["Target Identifier"] as? String) ?? (lockdown["UniqueDeviceID"] as? String) ?? url.lastPathComponent
        let snapshot = status["SnapshotState"] as? String
        return IOSBackupInfo(
            id: url.lastPathComponent,
            url: url,
            deviceName: (info["Device Name"] as? String) ?? (info["Display Name"] as? String) ?? (lockdown["DeviceName"] as? String) ?? "iPhone",
            productType: (info["Product Type"] as? String) ?? (lockdown["ProductType"] as? String),
            productVersion: (info["Product Version"] as? String) ?? (lockdown["ProductVersion"] as? String),
            date: (info["Last Backup Date"] as? Date) ?? (status["Date"] as? Date) ?? (manifest["Date"] as? Date),
            isEncrypted: (manifest["IsEncrypted"] as? Bool) ?? ((manifest["IsEncrypted"] as? NSNumber)?.boolValue ?? false),
            isComplete: snapshot == nil || snapshot == "finished",
            udid: udid
        )
    }
}

enum BackupStore {
    enum Failure: LocalizedError {
        case noAccess
        var errorDescription: String? { "macOS keeps iPhone backups private. Give DiskScout Full Disk Access to read them." }
    }

    /// Where Finder keeps backups. A `DISKSCOUT_BACKUP_ROOT` environment variable overrides it
    /// (used for tests and sample data).
    static var root: URL {
        if let custom = ProcessInfo.processInfo.environment["DISKSCOUT_BACKUP_ROOT"], !custom.isEmpty {
            return URL(fileURLWithPath: custom, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MobileSync/Backup", isDirectory: true)
    }

    /// Every backup on this Mac, newest first. Throws `noAccess` without Full Disk Access.
    static func list(root: URL = BackupStore.root) throws -> [IOSBackupInfo] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let names: [String]
        do {
            names = try fm.contentsOfDirectory(atPath: root.path)
        } catch let e as NSError where e.domain == NSCocoaErrorDomain && (e.code == NSFileReadNoPermissionError || e.code == 257) {
            throw Failure.noAccess
        } catch let e as NSError where e.domain == NSPOSIXErrorDomain && (e.code == Int(EPERM) || e.code == Int(EACCES)) {
            throw Failure.noAccess
        }
        return names.filter { !$0.hasPrefix(".") }
            .compactMap { IOSBackupInfo.read(at: root.appendingPathComponent($0, isDirectory: true)) }
            .sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }
}
