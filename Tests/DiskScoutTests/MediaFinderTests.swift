import XCTest
@testable import DiskScout

final class MediaFinderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("diskscout-media-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("skipme"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Lib.photoslibrary/inner"), withIntermediateDirectories: true)
        try Data(count: 1_000).write(to: dir.appendingPathComponent("top.jpg"))
        try Data(count: 2_000).write(to: dir.appendingPathComponent("a/clip.MOV"))
        try Data(count: 3_000).write(to: dir.appendingPathComponent("a/b/c/song.mp3"))
        try Data(count: 4_000).write(to: dir.appendingPathComponent("a/b/notes.txt"))
        try Data(count: 5_000).write(to: dir.appendingPathComponent("a/.hidden.png"))
        try Data(count: 6_000).write(to: dir.appendingPathComponent("skipme/x.png"))
        try Data(count: 7_000).write(to: dir.appendingPathComponent("Lib.photoslibrary/inner/raw.jpg"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func walk(includeHidden: Bool, excluded: Set<String> = []) -> [MediaItem] {
        var out: [MediaItem] = []
        _ = MediaFinder.walk(root: dir, options: ScanOptions(includeHidden: includeHidden, excludedPaths: excluded), cancelled: { false }) { batch, _ in
            out.append(contentsOf: batch)
        }
        return out
    }

    func testFindsNestedMediaAndSkipsDocuments() {
        let items = walk(includeHidden: true)
        let names = Set(items.map(\.name))
        XCTAssertTrue(names.contains("top.jpg"))
        XCTAssertTrue(names.contains("clip.MOV"), "extension matching must be case-insensitive")
        XCTAssertTrue(names.contains("song.mp3"))
        XCTAssertTrue(names.contains(".hidden.png"))
        XCTAssertFalse(names.contains("notes.txt"))
        XCTAssertEqual(items.first { $0.name == "song.mp3" }?.relativeFolder, "a/b/c")
        XCTAssertEqual(items.first { $0.name == "song.mp3" }?.kind, .audio)
        XCTAssertEqual(items.first { $0.name == "clip.MOV" }?.kind, .videos)
    }

    func testPhotosLibraryIsOneItemNotItsContents() {
        let items = walk(includeHidden: true)
        XCTAssertFalse(items.contains { $0.name == "raw.jpg" }, "package descendants must not be listed individually")
        let lib = items.first { $0.name == "Lib.photoslibrary" }
        XCTAssertNotNil(lib)
        XCTAssertEqual(lib?.kind, .photos)
        XCTAssertTrue(lib?.isPackage ?? false)
        XCTAssertGreaterThanOrEqual(lib?.size ?? 0, 7_000)
    }

    func testHiddenAndExcludedAreHonoured() {
        let items = walk(includeHidden: false, excluded: [dir.appendingPathComponent("skipme").path])
        let names = Set(items.map(\.name))
        XCTAssertFalse(names.contains(".hidden.png"))
        XCTAssertFalse(names.contains("x.png"))
        XCTAssertTrue(names.contains("top.jpg"))
    }

    func testCancellationStopsEarly() {
        var count = 0
        var calls = 0
        _ = MediaFinder.walk(root: dir, options: ScanOptions(), cancelled: { calls += 1; return calls > 2 }) { batch, _ in
            count += batch.count
        }
        XCTAssertLessThan(count, 5)
    }

    func testMediaCategoryIgnoresPathRules() {
        XCTAssertEqual(FileCategory.mediaCategory(forExtension: "JPG"), .photos)
        XCTAssertEqual(FileCategory.mediaCategory(forExtension: "webm"), .video)
        XCTAssertEqual(FileCategory.mediaCategory(forExtension: "flac"), .audio)
        XCTAssertNil(FileCategory.mediaCategory(forExtension: "sketch"), "design sources are not browsable media")
        XCTAssertNil(FileCategory.mediaCategory(forExtension: "pdf"))
        XCTAssertNil(FileCategory.mediaCategory(forExtension: ""))
    }
}
