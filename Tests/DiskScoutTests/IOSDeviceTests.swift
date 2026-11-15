import XCTest
import SQLite3
@testable import DiskScout

final class IOSDeviceTests: XCTestCase {

    private func app(_ id: String, _ name: String, data: Int64 = 100_000_000, fileSharing: Bool = false) -> IOSApp {
        IOSApp(id: id, name: name, version: "1.0", appSize: 50_000_000, dataSize: data, fileSharing: fileSharing)
    }

    func testOrdinaryAppsAreReviewNeverSafe() {
        let a = app("com.burbn.instagram", "Instagram", data: 1_800_000_000)
        XCTAssertEqual(a.assessment.level, .review)
        XCTAssertNotNil(a.tip)
        // Deleting on the iPhone is permanent, so no app is ever rated Safe.
        for (id, name) in [("com.spotify.client", "Spotify"), ("com.example.game", "Some Game")] {
            XCTAssertNotEqual(app(id, name).assessment.level, .safe)
        }
    }

    func testAppsThatMayHoldIrreplaceableDataAreCaution() {
        XCTAssertEqual(app("net.whatsapp.WhatsApp", "WhatsApp").assessment.level, .caution)
        XCTAssertEqual(app("org.whispersystems.signal", "Signal").assessment.level, .caution)
        XCTAssertEqual(app("com.google.Authenticator", "Authenticator").assessment.level, .caution)
        XCTAssertEqual(app("com.example.otp", "Acme Authenticator").assessment.level, .caution)
        XCTAssertEqual(app("io.metamask.MetaMask", "MetaMask").assessment.level, .caution)
        XCTAssertEqual(app("com.example.crypto", "Trust Wallet").assessment.level, .caution)
        // Documents visible in Files/Finder are the user's own files.
        XCTAssertEqual(app("org.videolan.vlc", "VLC", data: 3_000_000_000, fileSharing: true).assessment.level, .caution)
        XCTAssertEqual(app("org.videolan.vlc", "VLC", data: 1_000_000, fileSharing: true).assessment.level, .review)
    }

    func testCrashLogsAreSafe() {
        XCTAssertEqual(SafetyClassifier.iosCrashLogs.level, .safe)
    }

    func testParsesInstallationProxyEntry() {
        let a = IOSApp(bundleID: "com.google.ios.youtube", attributes: [
            "CFBundleDisplayName": "YouTube",
            "CFBundleShortVersionString": "20.45.3",
            "StaticDiskUsage": NSNumber(value: 362_800_000),
            "DynamicDiskUsage": NSNumber(value: 1_124_000_000),
            "UIFileSharingEnabled": false,
        ])
        XCTAssertEqual(a?.name, "YouTube")
        XCTAssertEqual(a?.version, "20.45.3")
        XCTAssertEqual(a?.appSize, 362_800_000)
        XCTAssertEqual(a?.dataSize, 1_124_000_000)
        XCTAssertEqual(a?.totalSize, 1_486_800_000)
        XCTAssertEqual(a?.fileSharing, false)

        // Falls back to CFBundleName, then the bundle id; missing sizes count as zero.
        XCTAssertEqual(IOSApp(bundleID: "a.b", attributes: ["CFBundleName": "Thing"])?.name, "Thing")
        let bare = IOSApp(bundleID: "a.b.c", attributes: ["CFBundleDisplayName": ""])
        XCTAssertEqual(bare?.name, "a.b.c")
        XCTAssertEqual(bare?.totalSize, 0)
    }

    func testMediaFoldersGroupIntoFriendlyBuckets() {
        XCTAssertEqual(DeviceMediaUsage.group(for: "DCIM").title, "Photos & videos")
        XCTAssertEqual(DeviceMediaUsage.group(for: "PhotoData").id, DeviceMediaUsage.group(for: "MediaAnalysis").id)
        XCTAssertEqual(DeviceMediaUsage.group(for: "iTunes_Control").id, "music")
        XCTAssertEqual(DeviceMediaUsage.group(for: "SomethingNew").id, "other")
    }

    private func log(_ name: String, in dir: String = "") -> DeviceLogInfo {
        DeviceLogInfo.parse(DeviceFile(domain: .crashLogs, path: dir + "/" + name, size: 1000, isDirectory: false, date: nil))
    }

    func testParsesRealCrashLogNames() {
        let crash = log("WhatsApp-2026-11-10-093012.ips")
        XCTAssertEqual(crash.process, "WhatsApp")
        XCTAssertEqual(crash.type, "Crash")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day, .hour], from: crash.date!), DateComponents(year: 2026, month: 11, day: 10, hour: 9))

        XCTAssertEqual(log("ANECompilerService.cpu_resource-2026-10-24-132700.ips").type, "Heavy CPU use")
        XCTAssertEqual(log("Flipkart.cpu_resource_fatal-2026-10-24-132700.ips").type, "Stopped for CPU use")
        let webkit = log("com.apple.WebKit.Networking.diskwrites_resource-2026-10-24-132700.ips")
        XCTAssertEqual(webkit.process, "com.apple.WebKit.Networking")
        XCTAssertEqual(webkit.type, "Heavy disk writes")

        let fault = log("ExcUserFault_SpringBoard-2026-11-01-101010.0002.ips")
        XCTAssertEqual(fault.process, "SpringBoard")
        XCTAssertEqual(fault.type, "Non-fatal fault")
        XCTAssertNotNil(fault.date)

        let numbered = log("SiriSearchFeedback-2026-11-01-101010.000.ips")
        XCTAssertEqual(numbered.process, "SiriSearchFeedback")
        XCTAssertEqual(numbered.type, "Diagnostic report")
        XCTAssertEqual(log("JetsamEvent-2026-11-01-101010.ips").type, "Low-memory event")
        XCTAssertEqual(log("LowBatteryLog-2026-11-01-101010.ips").type, "Battery log")
        XCTAssertEqual(log("spotlight_heartbeat_last.log", in: "/DiagnosticLogs/Search").type, "Diagnostic log")
    }

    func testDeviceFileKindsAndRatings() {
        func file(_ path: String, dir: Bool = false) -> DeviceFile { DeviceFile(domain: .media, path: path, size: 1, isDirectory: dir, date: nil) }
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0001.HEIC").kind, .photo)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0002.PNG").kind, .screenshot)
        XCTAssertEqual(file("/Downloads/x.png").kind, .photo)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0003.MOV").kind, .video)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0003.AAE").kind, .photoEdit)
        XCTAssertEqual(file("/PhotoData/Photos.sqlite").kind, .database)
        XCTAssertEqual(file("/DCIM", dir: true).kind, .folder)
        // Photos' own library files must never look deletable.
        XCTAssertEqual(file("/PhotoData/Photos.sqlite").assessment.level, .protected)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0001.HEIC").assessment.level, .review)
        XCTAssertEqual(file("/Books/book.epub").assessment.level, .caution)
        XCTAssertEqual(DeviceFile(domain: .crashLogs, path: "/a.ips", size: 1, isDirectory: false, date: nil).assessment.level, .safe)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_0001.HEIC").parentPath, "/DCIM/100APPLE")
        XCTAssertEqual(DeviceFile(domain: .crashLogs, path: "/x.ips", size: 1, isDirectory: false, date: nil).previewName, "x.ips.txt")
    }

    func testMediaKindsForShowMedia() {
        func file(_ path: String) -> DeviceFile { DeviceFile(domain: .media, path: path, size: 1, isDirectory: false, date: nil) }
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_1.HEIC").mediaKind, .photos)
        XCTAssertEqual(file("/DCIM/100APPLE/IMG_2.PNG").mediaKind, .photos)
        XCTAssertEqual(file("/PhotoData/Mutations/DCIM/100APPLE/IMG_3/Adjustments/FullSizeRender.mov").mediaKind, .videos)
        XCTAssertEqual(file("/iTunes_Control/Music/F00/song.m4a").mediaKind, .audio)
        XCTAssertNil(file("/PhotoData/Photos.sqlite").mediaKind)
        XCTAssertNil(file("/DCIM/100APPLE/IMG_1.AAE").mediaKind)
        XCTAssertEqual(DeviceMediaRequest(deviceID: "x", path: "/PhotoData/Mutations").folderName, "Mutations")
        XCTAssertEqual(DeviceMediaRequest(deviceID: "x", path: "/").folderName, "iPhone")
    }

    func testParsesWhereAppDataLives() {
        let a = IOSApp(bundleID: "com.burbn.instagram", attributes: [
            "CFBundleDisplayName": "Instagram",
            "GroupContainers": ["group.com.facebook.family": "/private/var/x", "group.com.burbn.instagram": "/private/var/y"],
            "Entitlements": ["com.apple.developer.icloud-container-identifiers": ["iCloud.com.burbn.instagram"],
                             "com.apple.developer.ubiquity-container-identifiers": ["iCloud.com.burbn.instagram", "iCloud.com.burbn.instagram.encryptedBackups"]],
            "NSPhotoLibraryAddUsageDescription": "Save photos",
        ])!
        XCTAssertEqual(a.groups, ["group.com.burbn.instagram", "group.com.facebook.family"])
        XCTAssertEqual(a.iCloudContainers, ["iCloud.com.burbn.instagram", "iCloud.com.burbn.instagram.encryptedBackups"])
        XCTAssertTrue(a.usesICloud)
        XCTAssertTrue(a.canSaveToPhotos)

        // Groups fall back to the entitlement; key-value iCloud alone still counts as iCloud.
        let b = IOSApp(bundleID: "com.spotify.client", attributes: [
            "Entitlements": ["com.apple.security.application-groups": ["group.com.spotify.client.widget"],
                             "com.apple.developer.ubiquity-kvstore-identifier": "2FNC3A47ZF.com.spotify.client"],
        ])!
        XCTAssertEqual(b.groups, ["group.com.spotify.client.widget"])
        XCTAssertTrue(b.usesICloud)
        XCTAssertTrue(b.iCloudContainers.isEmpty)
        XCTAssertFalse(b.canSaveToPhotos)
    }

    func testPhotoSourceNames() {
        XCTAssertEqual(PhotoSource.make(bundleID: "com.apple.replayd", displayName: nil).name, "Screen recordings")
        XCTAssertFalse(PhotoSource.make(bundleID: "com.apple.camera", displayName: "Camera").isApp)
        let wa = PhotoSource.make(bundleID: "net.whatsapp.WhatsApp", displayName: "\u{200E}WhatsApp")
        XCTAssertEqual(wa.name, "WhatsApp")
        XCTAssertTrue(wa.isApp)
        XCTAssertEqual(PhotoSource.make(bundleID: "", displayName: nil).id, PhotoSource.unknownID)
        XCTAssertEqual(PhotoSource.make(bundleID: "pinterest", displayName: nil).name, "pinterest")
        XCTAssertEqual(PhotoSource.assetKey(folder: "DCIM/104APPLE", baseName: "img_4805"), "/DCIM/104APPLE/IMG_4805")
    }

    func testReadsPhotoSourcesFromDatabase() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("photos-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        let sql = """
            CREATE TABLE ZASSET (Z_PK INTEGER PRIMARY KEY, ZDIRECTORY VARCHAR, ZFILENAME VARCHAR, ZTRASHEDSTATE INTEGER);
            CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER PRIMARY KEY, ZASSET INTEGER, ZIMPORTEDBYBUNDLEIDENTIFIER VARCHAR, ZIMPORTEDBYDISPLAYNAME VARCHAR);
            INSERT INTO ZASSET VALUES (1, 'DCIM/100APPLE', 'IMG_0001.HEIC', 0), (2, 'DCIM/100APPLE', 'IMG_0002.JPG', 0), (3, 'DCIM/101APPLE', 'IMG_0003.MOV', 1);
            INSERT INTO ZADDITIONALASSETATTRIBUTES VALUES (1, 1, 'com.apple.camera', 'Camera'), (2, 2, 'net.whatsapp.WhatsApp', 'WhatsApp'), (3, 3, NULL, NULL);
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let assets = try PhotoSourceReader.read(databaseAt: path).sorted { $0.key < $1.key }
        XCTAssertEqual(assets.map(\.key), ["/DCIM/100APPLE/IMG_0001", "/DCIM/100APPLE/IMG_0002", "/DCIM/101APPLE/IMG_0003"])
        XCTAssertEqual(assets.map(\.importer), ["com.apple.camera", "net.whatsapp.WhatsApp", ""])
        XCTAssertEqual(assets.map(\.trashed), [false, false, true])

        // An older or newer schema without the importer column is reported, not guessed at.
        let old = FileManager.default.temporaryDirectory.appendingPathComponent("photos-old-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: old) }
        XCTAssertEqual(sqlite3_open(old, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ZASSET (Z_PK INTEGER, ZDIRECTORY VARCHAR, ZFILENAME VARCHAR, ZTRASHEDSTATE INTEGER); CREATE TABLE ZADDITIONALASSETATTRIBUTES (Z_PK INTEGER, ZASSET INTEGER);", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertThrowsError(try PhotoSourceReader.read(databaseAt: old))
    }

    func testAppDocumentsAreaAndRatings() {
        let d = DeviceFileDomain.appDocuments("com.gopro.GoPro")
        XCTAssertEqual(d.key, "app-com.gopro.GoPro")
        XCTAssertEqual(d.rootPath, "/Documents")
        XCTAssertEqual(DeviceFileDomain.media.rootPath, "/")
        let db = DeviceFile(domain: d, path: "/Documents/MobeixDB.sqlite", size: 1, isDirectory: false, date: nil)
        XCTAssertEqual(db.assessment.level, .caution)
        let pdf = DeviceFile(domain: d, path: "/Documents/AcctStatement.pdf", size: 1, isDirectory: false, date: nil)
        XCTAssertEqual(pdf.assessment.level, .review)
        XCTAssertNotEqual(pdf.id, DeviceFile(domain: .media, path: "/Documents/AcctStatement.pdf", size: 1, isDirectory: false, date: nil).id)
    }

    func testStorageNumbers() {
        let info = IOSDeviceInfo(name: "Phone", model: "iPhone 13 Pro", productType: "iPhone14,2", osVersion: "26.3",
                                 deviceClass: "iPhone", capacity: 128_000_000_000, free: 8_000_000_000)
        XCTAssertEqual(info.used, 120_000_000_000)
        XCTAssertEqual(info.usedFraction, 0.9375, accuracy: 0.0001)
        XCTAssertEqual(info.osName, "iOS")
        XCTAssertEqual(IOSDeviceInfo(name: "", model: "", productType: "", osVersion: "", deviceClass: "iPad", capacity: 0, free: 0).osName, "iPadOS")
    }
}
