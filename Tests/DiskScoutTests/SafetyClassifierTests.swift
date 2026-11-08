import XCTest
@testable import DiskScout

final class SafetyClassifierTests: XCTestCase {
    let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path

    private func level(_ path: String, dir: Bool = true) -> SafetyLevel {
        SafetyClassifier.assess(url: URL(fileURLWithPath: path), isDirectory: dir).level
    }

    func testSystemPathsAreProtected() {
        XCTAssertEqual(level("/"), .protected)
        XCTAssertEqual(level("/System/Library/CoreServices/Finder.app"), .protected)
        XCTAssertEqual(level("/usr/bin/ls", dir: false), .protected)
        XCTAssertEqual(level("/private/var/db/dyld"), .protected)
        XCTAssertEqual(level(home), .protected)
        XCTAssertEqual(level(home + "/Library"), .protected)
        XCTAssertEqual(level(home + "/Documents"), .protected)
        XCTAssertEqual(level(home + "/Library/Keychains/login.keychain-db", dir: false), .protected)
        XCTAssertEqual(level(home + "/.ssh/id_ed25519", dir: false), .protected)
    }

    func testCachesAreSafeAndRegenerate() {
        let a = SafetyClassifier.assess(url: URL(fileURLWithPath: home + "/Library/Caches/com.example.app"), isDirectory: true)
        XCTAssertEqual(a.level, .safe)
        XCTAssertTrue(a.regenerates)
        XCTAssertEqual(level(home + "/Library/Logs/Foo/bar.log", dir: false), .safe)
        XCTAssertEqual(level(home + "/Library/Developer/Xcode/DerivedData/App-abc"), .safe)
        XCTAssertEqual(level(home + "/Library/Developer/Xcode/iOS DeviceSupport/17.0 (21A329)"), .safe)
        XCTAssertEqual(level(home + "/Library/Containers/com.foo.bar/Data/Library/Caches"), .safe)
        XCTAssertEqual(level(home + "/.npm/_cacache"), .safe)
        XCTAssertEqual(level(home + "/Library/Saved Application State/com.foo.savedState"), .safe)
        XCTAssertEqual(level(home + "/.Trash/old.zip", dir: false), .safe)
    }

    func testAppDataIsCaution() {
        XCTAssertEqual(level(home + "/Library/Application Support/Foo"), .caution)
        XCTAssertEqual(level(home + "/Library/Containers/com.foo.bar"), .caution)
        XCTAssertEqual(level(home + "/Library/Preferences/com.foo.plist", dir: false), .caution)
        XCTAssertEqual(level(home + "/Library/Mobile Documents/com~apple~CloudDocs/x.txt", dir: false), .caution)
        XCTAssertEqual(level(home + "/Library/Messages/chat.db", dir: false), .caution)
        XCTAssertEqual(level("/Applications/Safari.app"), .caution)
        XCTAssertEqual(level(home + "/Pictures/Photos Library.photoslibrary"), .caution)
    }

    func testPersonalFilesAreReview() {
        XCTAssertEqual(level(home + "/Downloads/movie.mp4", dir: false), .review)
        XCTAssertEqual(level(home + "/Documents/report.pdf", dir: false), .review)
        XCTAssertEqual(level(home + "/Library/Application Support/MobileSync/Backup/abc"), .review)
        XCTAssertEqual(level(home + "/Library/Developer/Xcode/Archives/2026-01-01"), .review)
        XCTAssertEqual(level("/Applications/SomeThirdParty.app"), .review)
        let installer = SafetyClassifier.assess(url: URL(fileURLWithPath: home + "/Downloads/App.dmg"), isDirectory: false)
        XCTAssertEqual(installer.level, .review)
        XCTAssertEqual(installer.headline, "Installer")
    }

    func testProjectBuildFoldersAreRegenerable() {
        let nm = SafetyClassifier.assess(url: URL(fileURLWithPath: home + "/Projects/web/node_modules"), isDirectory: true)
        XCTAssertEqual(nm.level, .safe)
        XCTAssertEqual(nm.recreateHint, "npm install")
        XCTAssertEqual(level(home + "/Projects/web/node_modules/react/index.js", dir: false), .safe)
        XCTAssertEqual(level(home + "/Projects/app/.build"), .safe)
        // A folder merely named "build" without project markers is not assumed regenerable.
        XCTAssertNotEqual(level(home + "/Documents/no-such-project-xyz/build"), .safe)
    }

    func testEveryAssessmentHasText() {
        for p in ["/", home, home + "/Library/Caches/x", home + "/Downloads/a.zip", "/Applications/X.app", "/Volumes/Ext/file"] {
            let a = SafetyClassifier.assess(url: URL(fileURLWithPath: p), isDirectory: !p.hasSuffix(".zip"))
            XCTAssertFalse(a.headline.isEmpty, p)
            XCTAssertFalse(a.explanation.isEmpty, p)
        }
    }
}

final class FileCategoryTests: XCTestCase {
    func testExtensions() {
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/x/a.jpg"), isDirectory: false, isPackage: false), .photos)
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/x/a.mov"), isDirectory: false, isPackage: false), .video)
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/x/a.swift"), isDirectory: false, isPackage: false), .developer)
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/x/a.dmg"), isDirectory: false, isPackage: false), .archives)
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/Applications/X.app"), isDirectory: true, isPackage: true), .apps)
        XCTAssertEqual(FileCategory.classify(url: URL(fileURLWithPath: "/Users/me/Library/Caches/a/b.bin"), isDirectory: false, isPackage: false), .caches)
    }
}

final class PathNormalizationTests: XCTestCase {
    func testVarAliasesResolveToPrivate() {
        XCTAssertEqual(SafetyClassifier.normalize("/var/folders/ab/cd"), "/private/var/folders/ab/cd")
        XCTAssertEqual(SafetyClassifier.normalize("/tmp"), "/private/tmp")
        XCTAssertEqual(SafetyClassifier.normalize("/variable/x"), "/variable/x")
        XCTAssertEqual(SafetyClassifier.assess(url: URL(fileURLWithPath: "/var/folders/zz/abc/T/x"), isDirectory: true).level, .protected)
        XCTAssertEqual(SafetyClassifier.assess(url: URL(fileURLWithPath: "/var/db/dslocal"), isDirectory: true).level, .protected)
    }
}
