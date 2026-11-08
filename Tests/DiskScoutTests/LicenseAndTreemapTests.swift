import XCTest
import CryptoKit
@testable import DiskScout

final class LicenseTests: XCTestCase {
    func testRejectsGarbage() {
        if case .failure(let e) = LicenseManager.verify("hello") { XCTAssertEqual(e, .malformed) } else { XCTFail() }
        if case .failure = LicenseManager.verify("DS1.eyJlIjoiYSJ9.AAAA") {} else { XCTFail("bad signature must fail") }
    }

    func testTamperedPayloadFails() throws {
        // Sign with a random key: must fail against the embedded public key.
        let key = Curve25519.Signing.PrivateKey()
        let payload = try JSONSerialization.data(withJSONObject: ["e": "x@y.z", "i": 0, "x": 0])
        let sig = try key.signature(for: payload)
        let token = "DS1.\(payload.base64URL).\(sig.base64URL)"
        if case .failure(let e) = LicenseManager.verify(token) { XCTAssertEqual(e, .badSignature) } else { XCTFail() }
    }

    func testEmbeddedPublicKeyIsValid() {
        let data = Data(hex: LicenseManager.publicKeyHex)
        XCTAssertEqual(data?.count, 32, "LicenseManager.publicKeyHex must be a 32-byte Ed25519 key")
    }

    func testBase64URLRoundTrip() {
        let d = Data((0..<64).map { UInt8($0 * 3 % 256) })
        XCTAssertEqual(Data(base64URL: d.base64URL), d)
    }
}

final class TreemapTests: XCTestCase {
    func testLayoutNeverProducesNaN() {
        let values = (0..<60).map { (id: UUID(), value: pow(10.0, Double($0 % 9))) }
        for size in [CGSize(width: 800, height: 500), CGSize(width: 3, height: 900), CGSize(width: 50, height: 1), CGSize(width: 0, height: 0)] {
            let tiles = Treemap.layout(values: values, in: CGRect(origin: .zero, size: size))
            for t in tiles {
                XCTAssertTrue(t.rect.width.isFinite && t.rect.height.isFinite && t.rect.minX.isFinite && t.rect.minY.isFinite)
                XCTAssertGreaterThan(t.rect.width, 0)
                XCTAssertGreaterThan(t.rect.height, 0)
            }
        }
    }

    func testAreasAreProportional() {
        let a = UUID(), b = UUID()
        let tiles = Treemap.layout(values: [(id: a, value: 300), (id: b, value: 100)], in: CGRect(x: 0, y: 0, width: 400, height: 100))
        let areaA = tiles.first { $0.id == a }!.rect.width * tiles.first { $0.id == a }!.rect.height
        let areaB = tiles.first { $0.id == b }!.rect.width * tiles.first { $0.id == b }!.rect.height
        XCTAssertEqual(areaA / areaB, 3, accuracy: 0.01)
    }
}

@MainActor
final class TrashManagerTests: XCTestCase {
    func testTrashAndPutBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskscout-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("junk.txt")
        try "hello".write(to: file, atomically: true, encoding: .utf8)

        let tm = TrashManager()
        let before = tm.history.count
        let record = try tm.trash(url: file, name: "junk.txt", size: 5, batchID: UUID())
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(tm.history.count, before + 1)
        try tm.putBack(record)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(tm.history.first { $0.id == record.id }!.restored)
        try? FileManager.default.removeItem(at: dir)
    }
}

final class ScanEngineTests: XCTestCase {
    @MainActor
    func testScanCountsSizes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskscout-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data(count: 10_000).write(to: dir.appendingPathComponent("a.bin"))
        try Data(count: 20_000).write(to: dir.appendingPathComponent("sub/b.bin"))

        let engine = ScanEngine()
        engine.scan(url: dir)
        for _ in 0..<200 where engine.isScanning { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(engine.isScanning)
        let root = try XCTUnwrap(engine.root)
        XCTAssertEqual(root.itemCount, 2)
        XCTAssertGreaterThanOrEqual(root.size, 30_000)
        XCTAssertEqual(root.children.count, 2)
        let sub = try XCTUnwrap(root.children.first { $0.name == "sub" })
        XCTAssertEqual(sub.itemCount, 1)
        XCTAssertEqual(engine.node(for: dir.appendingPathComponent("sub/b.bin"))?.name, "b.bin")
        try? FileManager.default.removeItem(at: dir)
    }
}

final class TrashPermissionTests: XCTestCase {
    func testPermissionErrorsAreRecognised() {
        XCTAssertTrue(TrashManager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)))
        XCTAssertTrue(TrashManager.isPermissionError(NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))))
        XCTAssertTrue(TrashManager.isPermissionError(NSError(domain: "x", code: 1, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])))
        XCTAssertFalse(TrashManager.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }

    func testPermissionErrorMessageMentionsFullDiskAccess() {
        let e = TrashError.permissionDenied(name: "Foo", finderMessage: nil)
        XCTAssertTrue(e.isPermission)
        XCTAssertTrue(e.localizedDescription.contains("Full Disk Access"))
    }
}

final class GumroadLicenseTests: XCTestCase {
    func testRecognisesGumroadKeyShape() {
        XCTAssertTrue(LicenseManager.isGumroadKey("ABCDEF12-34567890-ABCDEF12-34567890"))
        XCTAssertTrue(LicenseManager.isGumroadKey("abcdef12-34567890-abcdef12-34567890"))
        XCTAssertFalse(LicenseManager.isGumroadKey("DS1.abc.def"))
        XCTAssertFalse(LicenseManager.isGumroadKey("ABCDEF12-34567890-ABCDEF12"))
        XCTAssertFalse(LicenseManager.isGumroadKey("ABCDEF12-34567890-ABCDEF12-3456789G"))
    }

    func testGumroadKeyWithoutProductIDFailsCleanlyOffline() async {
        // Unit tests have no Info.plist, so the product ID is empty: no network call must be attempted.
        let result = await LicenseManager.verifyGumroad("ABCDEF12-34567890-ABCDEF12-34567890")
        if case .failure(let e) = result { XCTAssertEqual(e, .notConfigured) } else { XCTFail("expected notConfigured") }
    }
}
