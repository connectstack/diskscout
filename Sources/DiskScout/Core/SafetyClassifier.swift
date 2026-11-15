import Foundation
import SwiftUI

/// How risky is it to delete this item? This is the core promise of DiskScout:
/// every item gets a level and a plain-English reason.
enum SafetyLevel: Int, Comparable, CaseIterable, Codable, Hashable {
    case safe = 0       // Regenerable junk. Only frees space.
    case review = 1     // Personal files or things only the user can judge.
    case caution = 2    // App data. Deleting may break an app or lose data.
    case protected = 3  // macOS needs it. DiskScout refuses to delete.

    static func < (a: SafetyLevel, b: SafetyLevel) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self {
        case .safe:      return "Safe to remove"
        case .review:    return "Your call"
        case .caution:   return "Caution"
        case .protected: return "Protected"
        }
    }

    var shortTitle: String {
        switch self {
        case .safe:      return "Safe"
        case .review:    return "Review"
        case .caution:   return "Caution"
        case .protected: return "Protected"
        }
    }

    var color: Color {
        switch self {
        case .safe:      return Color(red: 0.20, green: 0.78, blue: 0.45)
        case .review:    return Color(red: 0.30, green: 0.60, blue: 1.00)
        case .caution:   return Color(red: 1.00, green: 0.62, blue: 0.20)
        case .protected: return Color(red: 0.95, green: 0.33, blue: 0.36)
        }
    }

    var systemImage: String {
        switch self {
        case .safe:      return "checkmark.shield.fill"
        case .review:    return "questionmark.circle.fill"
        case .caution:   return "exclamationmark.triangle.fill"
        case .protected: return "lock.shield.fill"
        }
    }

    var tagline: String {
        switch self {
        case .safe:      return "Rebuilt automatically by macOS or the app. Deleting it only frees space."
        case .review:    return "A personal file, or something only you can judge. Preview it before you decide."
        case .caution:   return "App data or settings. Deleting can break an app or lose saved information."
        case .protected: return "macOS needs this to run. DiskScout will never delete it."
        }
    }
}

struct SafetyAssessment: Equatable, Hashable {
    let level: SafetyLevel
    /// Short label, e.g. "App cache", "Xcode build products".
    let headline: String
    /// One or two sentences: what this is and what happens if you delete it.
    let explanation: String
    /// True when the item is recreated automatically (or with a single command).
    let regenerates: Bool
    /// Optional note like "Recreate with: npm install".
    let recreateHint: String?

    init(_ level: SafetyLevel, _ headline: String, _ explanation: String, regenerates: Bool = false, recreateHint: String? = nil) {
        self.level = level
        self.headline = headline
        self.explanation = explanation
        self.regenerates = regenerates
        self.recreateHint = recreateHint
    }

    var canDelete: Bool { level != .protected }
    var needsExtraConfirmation: Bool { level == .caution }
}

enum SafetyClassifier {

    static let home: String = AppPaths.home.standardizedFileURL.path

    // MARK: - Public

    static func assess(url: URL, isDirectory: Bool) -> SafetyAssessment {
        let std = url.standardizedFileURL
        let path = Self.normalize(std.path)
        let name = std.lastPathComponent
        let ext = std.pathExtension.lowercased()
        let parentPath = std.deletingLastPathComponent().path

        // 1. Hard-protected system locations.
        if hardBlockExact.contains(path) {
            return .init(.protected, "Core system folder",
                         "“\(displayName(path))” is part of macOS itself. Removing it would stop your Mac from booting or break every app.")
        }
        if path == home {
            return .init(.protected, "Your home folder", "This is your entire user account: every document, photo, setting and app login. It cannot be deleted from here.")
        }
        if parentPath == home, protectedHomeChildren.contains(name) {
            return .init(.protected, "Standard home folder",
                         "macOS and most apps expect “\(name)” to exist. Delete items inside it instead of the folder itself.")
        }
        for prefix in hardBlockPrefixes where path == prefix || path.hasPrefix(prefix + "/") {
            return .init(.protected, "System file",
                         "This lives inside \(prefix), which macOS needs to run. Apple keeps it sealed and read-only for a reason.")
        }
        if path == "/Users/Shared" {
            return .init(.protected, "Shared users folder", "Files shared between user accounts on this Mac live here.")
        }

        // 2. Secrets & credentials in the home folder.
        if under(path, home + "/.ssh") || under(path, home + "/.gnupg") {
            return .init(.protected, "Encryption keys",
                         "SSH or GPG keys and known hosts. Losing these can lock you out of servers, GitHub and encrypted mail. They are tiny; there's nothing to gain by deleting them.")
        }

        // 3. The Trash itself.
        if path == home + "/.Trash" {
            // Emptying is the one Mac action here that can't be undone, so it is never bulk-selected as Safe.
            return .init(.review, "Trash", "Files you already threw away. Emptying the Trash is permanent: nothing in it can be put back afterwards, including anything DiskScout moved there.")
        }
        if under(path, home + "/.Trash") {
            return .init(.safe, "Already in Trash", "You already deleted this. Emptying the Trash removes it permanently and frees the space.", regenerates: true)
        }

        // 4. Home Library — the big one.
        let libraryRoot = home + "/Library"
        if path == libraryRoot {
            return .init(.protected, "Your Library", "All your app settings and data. Never delete it as a whole — clean inside it instead.")
        }
        if path.hasPrefix(libraryRoot + "/") {
            let rel = String(path.dropFirst(libraryRoot.count + 1))
            if let hit = assessHomeLibrary(relative: rel, name: name, ext: ext, isDirectory: isDirectory) {
                return hit
            }
        }

        // 5. Developer project folders anywhere (node_modules, .build, Pods…).
        if isDirectory, let regen = regenerableProjectFolder(name: name, parentPath: parentPath) {
            return regen
        }
        if let inside = insideRegenerableProjectFolder(path: path) {
            return inside
        }

        // 6. Dotfiles in home.
        if parentPath == home, name.hasPrefix(".") {
            return assessHomeDotfile(name: name, isDirectory: isDirectory)
        }
        if let dotParent = homeDotfileParent(of: path) {
            if let cache = toolCacheSubfolder(path: path) { return cache }
            return assessHomeDotfile(name: dotParent, isDirectory: true, nested: true)
        }

        // 7. Applications.
        if parentPath == "/Applications" || parentPath == home + "/Applications" {
            if ext == "app" {
                if appleBundledApps.contains(name) {
                    return .init(.caution, "Apple app",
                                 "“\(name)” ships with macOS. If you remove it, the only way back is reinstalling macOS.")
                }
                return .init(.review, "Application",
                             "Deleting removes the app itself. Its settings and data in Library stay behind — Smart Clean can find those as leftovers afterwards.")
            }
            return .init(.review, "Item in Applications", "Usually a helper folder installed alongside an app. Check which app it belongs to before deleting.")
        }
        if path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/") {
            return .init(.caution, "Inside an app bundle", "Deleting parts of an app will break it. Delete the whole app instead, then let Smart Clean remove its leftovers.")
        }

        // 8. Root-level Library (shared by all users).
        if path.hasPrefix("/Library/") {
            if under(path, "/Library/Caches") {
                return .init(.safe, "System-wide cache", "Temporary files shared by all users. Rebuilt automatically. Deleting may require your admin password.", regenerates: true)
            }
            if under(path, "/Library/Logs") {
                return .init(.safe, "System-wide logs", "Diagnostic logs. Useful only if you're troubleshooting right now.", regenerates: true)
            }
            if under(path, "/Library/Developer/CommandLineTools") {
                return .init(.caution, "Command Line Tools", "Compilers and headers used by Homebrew, Git and Xcode. Reinstall with “xcode-select --install” if removed.")
            }
            return .init(.caution, "Shared library item", "Settings, drivers or support files shared by every user on this Mac. Deleting can break apps or hardware for everyone.")
        }

        // 9. Other users and shared locations.
        if path.hasPrefix("/Users/"), !path.hasPrefix(home + "/"), path != home {
            return .init(.caution, "Another user's files", "This belongs to a different account on this Mac. Deleting it affects them, not you.")
        }
        if path.hasPrefix("/Volumes/") {
            return .init(.review, "External volume", "Lives on another disk. Deleting frees space there, not on your startup disk.")
        }
        if path.hasPrefix("/opt/homebrew") || path.hasPrefix("/usr/local") {
            if path.contains("/Homebrew/Library/Taps") || path.contains("/Cellar/") || path.contains("/Caskroom/") {
                return .init(.caution, "Homebrew package", "Installed with Homebrew. Remove it with “brew uninstall” so Homebrew stays consistent.")
            }
            return .init(.caution, "Homebrew / local tools", "Developer tools installed outside the App Store. Removing files here breaks whatever depends on them.")
        }
        if path.hasPrefix("/private/tmp") || path.hasPrefix("/tmp") {
            return .init(.safe, "Temporary file", "macOS clears this location on restart anyway.", regenerates: true)
        }
        if path.hasPrefix("/private/") {
            return .init(.caution, "System data", "Internal macOS state. Even when deletable, it's usually recreated and rarely worth the risk.")
        }

        // 10. Your own folders.
        if path.hasPrefix(home + "/") {
            return assessPersonal(path: path, name: name, ext: ext, isDirectory: isDirectory)
        }

        // 11. Fallback by extension.
        return byExtension(ext: ext, name: name, isDirectory: isDirectory)
            ?? .init(.review, isDirectory ? "Folder" : "File", "Nothing about this location flags it as risky, but DiskScout doesn't recognise it either. Preview it before deleting.")
    }

    /// Convenience used by `FileNode`.
    static func assess(_ node: FileNode) -> SafetyAssessment {
        assess(url: node.url, isDirectory: node.isDirectory)
    }

    // MARK: - Home Library

    private static func assessHomeLibrary(relative rel: String, name: String, ext: String, isDirectory: Bool) -> SafetyAssessment? {
        func is_(_ p: String) -> Bool { rel == p }
        func in_(_ p: String) -> Bool { rel == p || rel.hasPrefix(p + "/") }

        // Caches
        if is_("Caches") { return .init(.safe, "Caches folder", "All app caches. Apps rebuild them as needed; you may notice a slower first launch. Cleaning inside is better than deleting the folder.", regenerates: true) }
        if in_("Caches") {
            if rel.hasPrefix("Caches/com.apple.") || rel.hasPrefix("Caches/CloudKit") {
                return .init(.safe, "System cache", "Cached data for a macOS component. Rebuilt automatically; no settings or documents live here.", regenerates: true)
            }
            if rel.hasPrefix("Caches/Homebrew") { return .init(.safe, "Homebrew downloads", "Downloaded bottles and installers kept for reinstalling. Re-downloaded if ever needed (“brew cleanup” does the same).", regenerates: true, recreateHint: "brew cleanup") }
            if rel.hasPrefix("Caches/CocoaPods") { return .init(.safe, "CocoaPods cache", "Downloaded pod sources. Re-fetched by “pod install”.", regenerates: true, recreateHint: "pod install") }
            if rel.hasPrefix("Caches/pip") { return .init(.safe, "pip cache", "Downloaded Python packages. Re-downloaded on the next install.", regenerates: true) }
            if rel.hasPrefix("Caches/Yarn") || rel.hasPrefix("Caches/yarn") { return .init(.safe, "Yarn cache", "Downloaded JavaScript packages. Re-fetched by yarn as needed.", regenerates: true) }
            if rel.hasPrefix("Caches/go-build") { return .init(.safe, "Go build cache", "Compiled Go objects. Rebuilt on the next “go build”.", regenerates: true) }
            if rel.hasPrefix("Caches/com.apple.dt.Xcode") { return .init(.safe, "Xcode cache", "Xcode's own cache, including documentation and download indexes. Rebuilt on next launch.", regenerates: true) }
            if rel.hasPrefix("Caches/JetBrains") { return .init(.safe, "JetBrains IDE cache", "Index and compile caches for IntelliJ, PyCharm, etc. Re-indexed when you reopen a project.", regenerates: true) }
            if rel.hasPrefix("Caches/Google/Chrome") || rel.hasPrefix("Caches/com.google.Chrome") { return .init(.safe, "Chrome cache", "Web page cache. Sites load a touch slower once; you stay signed in.", regenerates: true) }
            if rel.hasPrefix("Caches/Firefox") || rel.hasPrefix("Caches/org.mozilla") { return .init(.safe, "Firefox cache", "Web page cache. Sites load a touch slower once; you stay signed in.", regenerates: true) }
            if rel.hasPrefix("Caches/com.apple.Safari") { return .init(.safe, "Safari cache", "Web page cache. Sites load a touch slower once; you stay signed in.", regenerates: true) }
            if rel.hasPrefix("Caches/com.spotify") { return .init(.safe, "Spotify cache", "Streamed music cache. Downloaded playlists for offline listening are stored separately and are not affected… unless you set Spotify's offline storage here.", regenerates: true) }
            if rel.hasPrefix("Caches/com.tinyspeck.slackmacgap") { return .init(.safe, "Slack cache", "Cached images and files from Slack. Re-downloaded as you scroll.", regenerates: true) }
            if rel.hasPrefix("Caches/ms-playwright") { return .init(.safe, "Playwright browsers", "Browser binaries for Playwright tests. Re-downloaded by “npx playwright install”.", regenerates: true, recreateHint: "npx playwright install") }
            return .init(.safe, "App cache", "Temporary files an app keeps to launch faster. The app rebuilds them automatically; you may notice a slightly slower first launch.", regenerates: true)
        }

        // Logs
        if in_("Logs") { return .init(.safe, "Log files", "Diagnostic text files written by apps and macOS. Only useful if you're troubleshooting a problem right now.", regenerates: true) }

        // Developer
        if in_("Developer/Xcode/DerivedData") { return .init(.safe, "Xcode build products", "Intermediate build files and indexes. Xcode regenerates them the next time you build (the first build will take longer).", regenerates: true) }
        if in_("Developer/Xcode/iOS DeviceSupport") || in_("Developer/Xcode/watchOS DeviceSupport") || in_("Developer/Xcode/tvOS DeviceSupport") || in_("Developer/Xcode/visionOS DeviceSupport") || in_("Developer/Xcode/macOS DeviceSupport") {
            return .init(.safe, "Device support symbols", "Debug symbols for every OS version you ever plugged a device in with. Xcode downloads them again automatically when you connect a device running that version.", regenerates: true)
        }
        if in_("Developer/Xcode/Archives") { return .init(.review, "Xcode archives", "Builds you submitted or exported. Needed to symbolicate crash reports from those releases. Delete only versions you no longer support.") }
        if in_("Developer/Xcode/UserData/Previews") || in_("Developer/Xcode/UserData/IB Support") { return .init(.safe, "Xcode preview cache", "SwiftUI preview and Interface Builder scratch builds. Rebuilt on demand.", regenerates: true) }
        if in_("Developer/Xcode/UserData") { return .init(.caution, "Xcode user data", "Your breakpoints, key bindings, schemes and snippets. Small, and annoying to lose.") }
        if in_("Developer/Xcode/Products") { return .init(.safe, "Xcode products", "Built products for the legacy build location. Rebuilt by building again.", regenerates: true) }
        if in_("Developer/CoreSimulator/Caches") { return .init(.safe, "Simulator cache", "Cached dyld data for the iOS Simulator. Rebuilt when a simulator boots.", regenerates: true) }
        if in_("Developer/CoreSimulator/Devices") {
            return .init(.review, "Simulator device", "A simulated iPhone, iPad or Watch, including any apps and test data installed on it. Xcode recreates simulators as needed, but anything you set up inside is lost. Xcode ▸ Settings ▸ Platforms can also remove unused runtimes.")
        }
        if in_("Developer/CoreSimulator/Volumes") || in_("Developer/CoreSimulator/Images") { return .init(.review, "Simulator runtime", "A downloaded iOS/watchOS/visionOS simulator runtime, often several GB each. Re-download from Xcode ▸ Settings ▸ Platforms. Keep the versions you test against.") }
        if in_("Developer/XCTestDevices") || in_("Developer/XCPGDevices") { return .init(.safe, "Test device clones", "Temporary simulator clones created by test runs and playgrounds. Recreated automatically.", regenerates: true) }
        if in_("Developer/Xcode/DocumentationCache") || in_("Developer/Shared/Documentation") { return .init(.safe, "Documentation cache", "Downloaded developer documentation. Re-downloaded when viewed.", regenerates: true) }
        if in_("Developer") { return .init(.review, "Developer tools data", "Used by Xcode and related tools. Usually re-creatable, but check what it is before deleting.") }

        // Mail / Messages / iCloud
        if in_("Containers/com.apple.mail/Data/Library/Mail Downloads") { return .init(.safe, "Mail attachment copies", "Copies of attachments you opened from Mail. The originals stay inside the emails themselves.", regenerates: true) }
        if in_("Mail") { return .init(.caution, "Mail data", "Your local mailboxes, including downloaded messages and drafts. IMAP/iCloud mail re-downloads, but anything “On My Mac” is only here.") }
        if in_("Messages") { return .init(.caution, "Messages history", "Your iMessage and SMS history with attachments. If Messages in iCloud is off, this is the only copy.") }
        if in_("Mobile Documents") { return .init(.caution, "iCloud Drive", "Files synced with iCloud Drive. Deleting here deletes them from iCloud and all your devices (recoverable for 30 days at icloud.com).") }
        if in_("CloudStorage") { return .init(.caution, "Cloud drive", "Files synced by Dropbox, Google Drive, OneDrive or similar. Deleting here deletes them in the cloud too.") }

        // Backups
        if in_("Application Support/MobileSync/Backup") { return .init(.review, "iPhone / iPad backup", "A full device backup made by Finder, often 5–50 GB. Keep it if you might restore that device; otherwise it's just taking space (Finder ▸ Manage Backups shows dates).") }

        // Application Support specifics
        if in_("Application Support/Steam/steamapps") { return .init(.review, "Steam games", "Installed games. Re-downloadable from Steam, but large. Uninstall through Steam to keep its library in sync.") }
        if in_("Application Support/Code/CachedData") || in_("Application Support/Code/CachedExtensionVSIXs") || in_("Application Support/Code/Cache") || in_("Application Support/Code/CachedProfilesData") {
            return .init(.safe, "VS Code cache", "Cached extension and renderer data. Rebuilt on next launch.", regenerates: true)
        }
        if in_("Application Support/Google/Chrome") {
            if rel.contains("/Cache") || rel.contains("/Service Worker/CacheStorage") || rel.contains("/GPUCache") || rel.contains("/Code Cache") {
                return .init(.safe, "Chrome cache", "Cached web data. Sites load slightly slower once.", regenerates: true)
            }
            return .init(.caution, "Chrome profile", "Bookmarks, history, saved passwords and extensions. Deleting signs you out and loses anything not synced.")
        }
        if in_("Application Support/Firefox") { return .init(.caution, "Firefox profile", "Bookmarks, history, saved logins and extensions.") }
        if in_("Application Support/Slack/Cache") || in_("Application Support/Slack/Service Worker") { return .init(.safe, "Slack cache", "Cached images and web data. Re-downloaded as needed.", regenerates: true) }
        if in_("Application Support/discord/Cache") || in_("Application Support/discord/Code Cache") || in_("Application Support/discord/GPUCache") { return .init(.safe, "Discord cache", "Cached images and web data. Re-downloaded as needed.", regenerates: true) }
        if in_("Application Support/Spotify/PersistentCache") { return .init(.safe, "Spotify cache", "Streaming cache. Downloads for offline listening are also stored here — check Spotify's offline settings before clearing.", regenerates: true) }
        if in_("Application Support/CrashReporter") { return .init(.safe, "Crash reporter data", "Crash log bookkeeping. Rebuilt automatically.", regenerates: true) }
        if in_("Application Support/Adobe/Common/Media Cache Files") || in_("Application Support/Adobe/Common/Media Cache") || in_("Application Support/Adobe/Common/Peak Files") {
            return .init(.safe, "Adobe media cache", "Preview and peak files Premiere and After Effects generate from your footage. Regenerated when you reopen a project.", regenerates: true)
        }
        if in_("Application Support/Zoom/data") { return .init(.review, "Zoom data", "Chat history, recordings bookkeeping and avatars.") }
        if in_("Application Support/Steam") { return .init(.caution, "Steam data", "Steam client data and shader caches.") }
        if in_("Application Support/minecraft") { return .init(.review, "Minecraft worlds and mods", "Your worlds live in here. Back them up before deleting anything.") }
        if in_("Application Support") { return .init(.caution, "App support data", "Apps store their settings, databases and saved state here. Many won't recover if this is removed; some will reset to factory defaults.") }

        // Containers
        if rel.hasPrefix("Containers/") || rel.hasPrefix("Group Containers/") {
            if rel.contains("/Data/Library/Caches") || rel.contains("/Data/Library/Logs") || rel.contains("/Data/tmp") {
                return .init(.safe, "Sandboxed app cache", "Temporary cache inside an app's sandbox. The app rebuilds it.", regenerates: true)
            }
            if rel.hasPrefix("Containers/com.docker.docker") || rel.hasPrefix("Group Containers/group.com.docker") {
                return .init(.review, "Docker data", "All your Docker images, containers and volumes live in one large disk image here. Run “docker system prune” to shrink it safely instead of deleting the file.", recreateHint: "docker system prune")
            }
            if rel.hasPrefix("Containers/com.apple.Safari") { return .init(.caution, "Safari data", "History, tabs, extensions and website data for Safari.") }
            if rel.hasPrefix("Containers/com.apple.Photos") || rel.hasPrefix("Containers/com.apple.photolibraryd") { return .init(.caution, "Photos app data", "Photos app state. Your actual library is in Pictures.") }
            if rel.hasPrefix("Containers/com.apple.") { return .init(.caution, "Apple app data", "Sandboxed data for a built-in app: preferences, account info and saved state.") }
            if rel.hasPrefix("Group Containers") { return .init(.caution, "Shared app data", "Data shared between an app and its extensions or sibling apps (for example a password manager and its browser extension).") }
            return .init(.caution, "App sandbox data", "Sandboxed preferences, account info and saved files for an app. Deleting may erase data you can't get back.")
        }

        // Misc Library
        if in_("Keychains") { return .init(.protected, "Keychains", "Your saved passwords, Wi-Fi networks and certificates. Deleting can lock you out of everything.") }
        if in_("Accounts") { return .init(.protected, "Internet accounts", "The database of your iCloud, Google and Exchange accounts. Deleting signs you out everywhere.") }
        if in_("Preferences") { return .init(.caution, "App settings", "Preference files (.plist). Deleting one resets that app to defaults — occasionally useful for fixing a misbehaving app, otherwise pointless: they're tiny.") }
        if in_("Saved Application State") { return .init(.safe, "Window state", "Remembers which windows an app had open. Rebuilt the next time you use the app.", regenerates: true) }
        if in_("HTTPStorages") { return .init(.review, "App web storage", "Cookies and HTTP caches used by apps' built-in web views. You may be signed out of some in-app web content.") }
        if in_("WebKit") { return .init(.review, "WebKit website data", "Local storage and caches for web content inside apps. Deleting may sign you out of in-app web views.") }
        if in_("Cookies") { return .init(.caution, "Cookies", "Website logins and sessions. Deleting signs you out of websites.") }
        if in_("Safari") { return .init(.caution, "Safari data", "Bookmarks, history and reading list.") }
        if in_("Fonts") { return .init(.review, "Installed fonts", "Fonts you installed. Documents using them will fall back to another font.") }
        if in_("Metadata") || in_("Suggestions") || in_("Biome") || in_("Trial") || in_("Daemon Containers") || in_("IdentityServices") || in_("Sharing") || in_("PersonalizationPortrait") || in_("DuetExpertCenter") || in_("com.apple.") || in_("Weather") || in_("Reminders") || in_("Calendars") || in_("AddressBook") || in_("Autosave Information") || in_("StatusKit") || in_("Shortcuts") || in_("Passes") || in_("Wallet") {
            return .init(.caution, "macOS personal data", "Spotlight, Siri, Calendar, Contacts and other system databases. macOS manages these itself; deleting can cause strange behaviour until it rebuilds them.")
        }
        if in_("LaunchAgents") { return .init(.caution, "Login items", "Tells macOS to start helper programs when you log in. Deleting stops those helpers; apps often reinstall them.") }
        if in_("Application Scripts") { return .init(.caution, "App scripts", "Automation scripts an app is allowed to run.") }
        if in_("Screen Savers") || in_("Sounds") || in_("Services") || in_("Dictionaries") || in_("Input Methods") || in_("Audio") || in_("ColorPickers") || in_("Printers") || in_("QuickLook") || in_("Spelling") || in_("Widgets") || in_("Workflows") || in_("Scripts") || in_("Automator") || in_("PreferencePanes") || in_("Internet Plug-Ins") || in_("Compositions") {
            return .init(.review, "Add-ons", "Extras you (or an app) installed: screen savers, plug-ins, dictionaries and the like. Removing them only removes that extra.")
        }
        if in_("iTunes") || in_("Music") { return .init(.caution, "Music & devices data", "iPhone software updates, ringtones and legacy iTunes data. “iPhone Software Updates” inside here is safe to delete.") }
        if in_("Group Containers") { return .init(.caution, "Shared app data", "Data shared between an app and its extensions.") }
        if in_("Caches") { return .init(.safe, "Cache", "Temporary data. Rebuilt automatically.", regenerates: true) }
        if in_("Printers") { return .init(.review, "Printer drivers", "Drivers and queues for printers you've used.") }
        if in_("Services") { return .init(.review, "Services", "Context-menu services installed by apps.") }
        if in_("Updates") || in_("SyncedPreferences") || in_("PreferencePanes") { return .init(.caution, "System state", "Managed by macOS.") }

        if in_("Google/GoogleSoftwareUpdate") || in_("Google") {
            if rel.contains("Cache") { return .init(.safe, "Google updater cache", "Downloads kept by Google's updater.", regenerates: true) }
            return .init(.caution, "Google software updater", "Keeps Chrome and other Google apps updated.")
        }

        return .init(.caution, "Library item", "Part of your user Library. Apps store settings and data here, so delete only what you recognise.")
    }

    // MARK: - Personal folders

    private static func assessPersonal(path: String, name: String, ext: String, isDirectory: Bool) -> SafetyAssessment {
        let rel = String(path.dropFirst(home.count + 1))
        let top = rel.split(separator: "/").first.map(String.init) ?? ""

        if ext == "photoslibrary" {
            return .init(.caution, "Photos library", "Every photo and video in the Photos app. If iCloud Photos is on, full-size originals may exist only here. Never delete without a backup.")
        }
        if ext == "imovielibrary" || ext == "fcpbundle" { return .init(.caution, "Video project library", "iMovie or Final Cut library with your projects and imported clips.") }
        if ext == "musiclibrary" || ext == "tvlibrary" { return .init(.caution, "Media library", "Your Music or TV app library.") }
        if ext == "logicx" || ext == "band" { return .init(.review, "Music project", "A GarageBand or Logic project.") }

        if let e = byExtension(ext: ext, name: name, isDirectory: isDirectory) { return e }

        switch top {
        case "Downloads":
            return .init(.review, "Download", "Something you downloaded. If it's an installer or a file you've already dealt with, it's likely safe to go. Preview it to be sure.")
        case "Desktop":
            return .init(.review, "Desktop item", "A file you left on your Desktop. Only you know if you still need it.")
        case "Documents":
            return .init(.review, "Document", "One of your personal files. Only you can judge; the Trash keeps it recoverable for 30 days.")
        case "Pictures":
            return .init(.review, "Picture", "A personal photo or image. Check the preview before deleting.")
        case "Movies":
            if rel.hasPrefix("Movies/TV/") { return .init(.review, "Apple TV download", "A show or film downloaded for offline viewing. Re-downloadable from the TV app.") }
            return .init(.review, "Video", "A personal video. These are often huge and often forgotten — check the preview.")
        case "Music":
            if rel.hasPrefix("Music/Music/Media") || rel.hasPrefix("Music/iTunes/iTunes Media") {
                if rel.contains("/Mobile Applications/") { return .init(.safe, "Legacy iOS app backup", "Old iOS app installers from the iTunes era. iOS no longer uses these.", regenerates: true) }
                return .init(.review, "Music file", "Part of your music library. Purchased music can be re-downloaded; imported CDs can't.")
            }
            return .init(.review, "Music file", "A personal audio file.")
        case "Public":
            return .init(.review, "Public folder item", "Shared with other users on your network or Mac.")
        case "Applications":
            return .init(.review, "Application", "An app installed just for your account.")
        default:
            if isDirectory {
                return .init(.review, "Folder", "A folder in your home directory. Browse inside to see what's taking the space.")
            }
            return .init(.review, "Personal file", "Nothing flags this as system or app data. Only you know if you still need it.")
        }
    }

    // MARK: - Dotfiles

    private static func homeDotfileParent(of path: String) -> String? {
        guard path.hasPrefix(home + "/.") else { return nil }
        let rel = String(path.dropFirst(home.count + 1))
        guard let first = rel.split(separator: "/").first, first.hasPrefix("."), rel.contains("/") else { return nil }
        return String(first)
    }

    /// The parts of tool folders that really are just re-downloadable caches.
    private static func toolCacheSubfolder(path: String) -> SafetyAssessment? {
        let caches: [(String, String)] = [
            (".bun/install/cache", "Bun"), (".yarn/cache", "Yarn"), (".yarn/berry/cache", "Yarn"),
            (".gradle/caches", "Gradle"), (".gradle/daemon", "Gradle"), (".gradle/wrapper/dists", "Gradle"),
        ]
        for (sub, tool) in caches where under(path, home + "/" + sub) || path == home + "/" + sub {
            return .init(.safe, "\(tool) cache", "Downloads \(tool) keeps so it doesn't fetch them again. Re-downloaded the next time they're needed.", regenerates: true)
        }
        return nil
    }

    private static func assessHomeDotfile(name: String, isDirectory: Bool, nested: Bool = false) -> SafetyAssessment {
        switch name {
        case ".cache":
            return .init(.safe, "Tool cache", "Caches for command-line tools (pip, Hugging Face, Puppeteer…). Rebuilt or re-downloaded as needed. Hugging Face models in here can be many GB.", regenerates: true)
        case ".npm":
            return .init(.safe, "npm cache", "Downloaded JavaScript packages. Re-fetched on the next install.", regenerates: true, recreateHint: "npm cache clean --force")
        case ".pnpm-store":
            return .init(.safe, "Package manager cache", "Downloaded JavaScript packages. Re-fetched on the next install.", regenerates: true)
        case ".yarn", ".bun":
            // These hold the tool itself and globally installed packages, not just a cache.
            return .init(.review, "Package manager folder", "Holds the tool itself (the “\(name == ".bun" ? "bun" : "yarn")” command), packages you installed globally, and a download cache. Only the cache subfolder is rebuilt automatically; deleting the whole folder removes the tool.")
        case ".gradle":
            return .init(.review, "Gradle home", "Download caches plus your own Gradle settings (gradle.properties can hold signing passwords and tokens). The “caches” subfolder is safe to remove; the rest is yours.")
        case ".m2":
            return .init(.review, "Maven repository", "Downloaded Java dependencies. Re-downloaded when you build, which can be slow on a bad connection.")
        case ".cargo":
            return .init(.review, "Cargo (Rust) data", "The registry cache inside is safe to delete; installed binaries in “bin” are not. Prefer “cargo cache -a” if you have it.")
        case ".rustup":
            return .init(.caution, "Rust toolchains", "Installed Rust compilers. Remove old ones with “rustup toolchain remove”.")
        case ".cocoapods":
            return .init(.safe, "CocoaPods specs", "The CocoaPods spec repository. Re-cloned by “pod install”.", regenerates: true, recreateHint: "pod install")
        case ".pub-cache":
            return .init(.review, "Dart / Flutter packages", "Downloaded packages. Re-fetched by “flutter pub get”.", recreateHint: "flutter pub get")
        case ".docker":
            return .init(.caution, "Docker settings", "Docker CLI config and contexts. Images live elsewhere (in Containers).")
        case ".ollama":
            return .init(.review, "Ollama models", "Downloaded AI models, often several GB each. Remove with “ollama rm <model>” or delete here and re-pull later.")
        case ".android":
            return .init(.review, "Android emulators", "Android Virtual Devices and their disk images. Delete unused ones from Android Studio's Device Manager.")
        case ".Trash":
            return .init(.safe, "Trash", "Already deleted.", regenerates: true)
        case ".config":
            return .init(.caution, "Tool configuration", "Settings for command-line tools and some apps.")
        case ".local":
            return .init(.caution, "Local tool data", "User-installed command-line tools and their data (pipx, uv, etc).")
        case ".vscode", ".cursor":
            return .init(.caution, "Editor extensions", "Installed extensions and settings for your editor. Re-installable, but tedious.")
        case ".zsh_history", ".bash_history", ".zshrc", ".bashrc", ".zprofile", ".bash_profile", ".gitconfig", ".vimrc", ".profile":
            return .init(.caution, "Shell configuration", "Your shell settings or history. Tiny, and painful to lose.")
        case ".ssh", ".gnupg":
            return .init(.protected, "Encryption keys", "Keys and credentials.")
        case ".CFUserTextEncoding", ".DS_Store":
            return .init(.safe, "System housekeeping file", "Recreated automatically by macOS.", regenerates: true)
        case ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems":
            return .init(.protected, "macOS index", "Spotlight and file system bookkeeping.")
        default:
            if isDirectory {
                return .init(.review, "Hidden tool folder", "Data for a command-line tool (“\(name)”). Often caches that can be rebuilt, but check what tool owns it first.")
            }
            return .init(.review, "Hidden file", "A configuration or state file for a command-line tool.")
        }
    }

    // MARK: - Project build folders

    private static let regenerableFolderNames: [String: (String, String, String?)] = [
        "node_modules": ("JavaScript dependencies", "Packages installed from npm/yarn/pnpm. Nothing of yours lives here.", "npm install"),
        ".build": ("Swift build output", "SwiftPM build products and intermediates.", "swift build"),
        "Pods": ("CocoaPods dependencies", "Installed pods. Nothing of yours lives here (keep the Podfile).", "pod install"),
        "DerivedData": ("Xcode build products", "Xcode intermediates for this project.", nil),
        "__pycache__": ("Python bytecode cache", "Compiled .pyc files. Recreated on import.", nil),
        ".pytest_cache": ("pytest cache", "Test run bookkeeping.", nil),
        ".mypy_cache": ("mypy cache", "Type-checker cache.", nil),
        ".ruff_cache": ("ruff cache", "Linter cache.", nil),
        ".next": ("Next.js build output", "Compiled Next.js pages.", "next build"),
        ".nuxt": ("Nuxt build output", "Compiled Nuxt output.", "nuxt build"),
        ".turbo": ("Turborepo cache", "Task cache.", nil),
        ".parcel-cache": ("Parcel cache", "Bundler cache.", nil),
        ".angular": ("Angular cache", "Build cache.", nil),
        ".dart_tool": ("Dart tool cache", "Package resolution and build cache.", "flutter pub get"),
        ".gradle": ("Gradle project cache", "Per-project Gradle cache.", nil),
        "Carthage": ("Carthage dependencies", "Built frameworks from Carthage.", "carthage bootstrap"),
        ".swiftpm": ("SwiftPM metadata", "Xcode's SwiftPM workspace state. Harmless to reset.", nil),
        "bower_components": ("Bower dependencies", "Legacy front-end packages.", "bower install"),
        ".terraform": ("Terraform providers", "Downloaded provider plug-ins.", "terraform init"),
        ".venv": ("Python virtual environment", "Installed packages for this project. Recreate from requirements.txt / pyproject.", "python -m venv .venv"),
        "venv": ("Python virtual environment", "Installed packages for this project. Recreate from requirements.txt / pyproject.", "python -m venv venv"),
        ".tox": ("tox environments", "Test environments.", "tox"),
        "Build": ("Build output", "Compiled output.", nil),
    ]

    private static func regenerableProjectFolder(name: String, parentPath: String) -> SafetyAssessment? {
        guard parentPath.hasPrefix(home + "/"), !parentPath.hasPrefix(home + "/Library") else { return nil }
        if let (headline, text, hint) = regenerableFolderNames[name] {
            if ambiguousFolderNames.contains(name) {
                // Only treat as regenerable when it clearly sits in a project folder.
                guard looksLikeProjectFolder(parentPath) else { return nil }
            }
            let level: SafetyLevel = (name == ".venv" || name == "venv") ? .review : .safe
            return .init(level, headline, text + (hint.map { " Recreate with “\($0)”." } ?? " Rebuilt automatically the next time you build."), regenerates: true, recreateHint: hint)
        }
        if name == "out" {
            // "out" is as often results you produced as it is build output.
            guard looksLikeProjectFolder(parentPath) else { return nil }
            return .init(.review, "Output folder", "Probably build output for the project in “\((parentPath as NSString).lastPathComponent)”, but “out” folders also hold results people generate on purpose. Look inside before deleting.")
        }
        if name == "build" || name == "dist" || name == "target" {
            guard looksLikeProjectFolder(parentPath) else { return nil }
            return .init(.safe, "Build output", "Compiled output for the project in “\((parentPath as NSString).lastPathComponent)”. Rebuilt the next time you build.", regenerates: true)
        }
        return nil
    }

    private static func insideRegenerableProjectFolder(path: String) -> SafetyAssessment? {
        guard path.hasPrefix(home + "/"), !path.hasPrefix(home + "/Library/") else { return nil }
        let comps = path.split(separator: "/").map(String.init)
        for (i, c) in comps.enumerated() where i < comps.count - 1 {
            if let (headline, _, hint) = regenerableFolderNames[c], c != "Build", c != ".gradle" {
                // A folder that just happens to be called "Pods" or "venv" isn't one unless a project sits beside it.
                if ambiguousFolderNames.contains(c), !looksLikeProjectFolder("/" + comps[..<i].joined(separator: "/")) { continue }
                return .init(.safe, "Inside \(headline.lowercased())", "Part of “\(c)”, which is rebuilt by your tools. Deleting the whole “\(c)” folder is cleaner than picking files out of it." + (hint.map { " Recreate with “\($0)”." } ?? ""), regenerates: true, recreateHint: hint)
            }
        }
        return nil
    }

    /// Names ordinary folders also have; these only count as build products next to a project.
    private static let ambiguousFolderNames: Set<String> = ["Build", ".gradle", "Pods", "Carthage", "DerivedData", "venv"]

    private static let projectMarkers = ["Cartfile", "requirements.txt", "package.json", "Package.swift", "Cargo.toml", "build.gradle", "build.gradle.kts", "CMakeLists.txt", "pom.xml", "pyproject.toml", "setup.py", "Makefile", "go.mod", "pubspec.yaml", "Gemfile", "mix.exs", "tsconfig.json", "Podfile", "project.pbxproj", "settings.gradle", "settings.gradle.kts"]

    private static func looksLikeProjectFolder(_ path: String) -> Bool {
        let fm = FileManager.default
        for m in projectMarkers where fm.fileExists(atPath: path + "/" + m) { return true }
        if let items = try? fm.contentsOfDirectory(atPath: path), items.contains(where: { $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) { return true }
        return false
    }

    // MARK: - Extensions

    private static let installerExt: Set<String> = ["dmg", "pkg", "mpkg", "xip", "iso", "img", "cdr"]
    private static let archiveExt: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "zst", "sit", "sitx"]
    private static let diagnosticExt: Set<String> = ["crash", "ips", "spin", "hang", "diag"]
    private static let junkExt: Set<String> = ["log", "tmp", "temp", "part", "crdownload", "download", "swp"]

    private static func byExtension(ext: String, name: String, isDirectory: Bool) -> SafetyAssessment? {
        if isDirectory { return nil }
        if installerExt.contains(ext) {
            return .init(.review, "Installer", "A disk image or installer package. Once the app is installed you don't need this — the app itself lives in Applications. Keep it only if you want to reinstall offline.")
        }
        if archiveExt.contains(ext) {
            return .init(.review, "Archive", "A compressed archive. If you already extracted it (look for a folder with the same name), this copy is redundant.")
        }
        if diagnosticExt.contains(ext) {
            return .init(.safe, "Crash or diagnostic report", "A report macOS or an app wrote when something went wrong. Nothing uses it afterwards.", regenerates: true)
        }
        if junkExt.contains(ext) {
            // Outside the Logs, Caches and temp locations (rated earlier), these can be yours:
            // a log you're keeping, a download you could resume, an editor's unsaved-changes file.
            return .init(.review, "Log or temporary file", "Usually leftover output or a half-finished download. Check it isn't a log you keep, a download you want to resume, or unsaved edits from a text editor.")
        }
        if ext == "xcarchive" { return .init(.review, "Xcode archive", "A build you archived for distribution. Needed to symbolicate crash reports from that release.") }
        if ext == "ipa" { return .init(.review, "iOS app package", "An exported iOS app build. Re-exportable from Xcode if you still have the archive.") }
        if ext == "dsym" { return .init(.review, "Debug symbols", "Needed to read crash reports for one specific build.") }
        if ext == "vmdk" || ext == "vdi" || ext == "qcow2" || ext == "utm" || ext == "pvm" || ext == "vmwarevm" || ext == "bundle" && name.contains("UTM") {
            return .init(.caution, "Virtual machine disk", "An entire virtual machine lives in this file. Deleting it deletes the VM and everything installed in it.")
        }
        if ext == "sparsebundle" || ext == "sparseimage" || ext == "backupbundle" {
            return .init(.caution, "Disk image / backup", "Possibly a Time Machine or encrypted disk image. Make sure you know what's inside before deleting.")
        }
        return nil
    }

    // MARK: - Helpers

    /// `/var`, `/tmp` and `/etc` are symlinks into `/private`; match rules against the real location.
    static func normalize(_ path: String) -> String {
        for (alias, real) in [("/var", "/private/var"), ("/tmp", "/private/tmp"), ("/etc", "/private/etc")] {
            if path == alias { return real }
            if path.hasPrefix(alias + "/") { return real + path.dropFirst(alias.count) }
        }
        return path
    }

    private static func under(_ path: String, _ prefix: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    private static func displayName(_ path: String) -> String {
        path == "/" ? "/ (the startup disk)" : (path as NSString).lastPathComponent
    }

    // MARK: - Lists

    static let hardBlockExact: Set<String> = [
        "/", "/Applications", "/Library", "/Users", "/System",
        "/private", "/usr", "/bin", "/sbin", "/var", "/etc", "/opt", "/tmp",
        "/private/var", "/private/etc", "/private/tmp",
        "/cores", "/dev", "/Volumes", "/Network", "/home", "/Users/Shared",
        "/Library/Application Support", "/Library/Preferences", "/Library/Caches", "/Library/Logs",
        "/opt/homebrew", "/usr/local"
    ]

    static let hardBlockPrefixes: [String] = [
        "/System", "/usr/bin", "/usr/lib", "/usr/libexec", "/usr/sbin", "/usr/share", "/usr/standalone",
        "/bin", "/sbin", "/cores", "/dev", "/Network",
        "/private/etc", "/private/var/db", "/private/var/folders", "/private/var/vm",
        "/private/var/root", "/private/var/protected", "/private/var/mobile", "/private/var/select", "/private/var/run",
        "/Library/Frameworks", "/Library/Extensions", "/Library/LaunchAgents", "/Library/LaunchDaemons",
        "/Library/PrivilegedHelperTools", "/Library/Apple", "/Library/Security", "/Library/Keychains",
        "/Library/StagedExtensions", "/Library/SystemExtensions", "/Library/Filesystems", "/Library/Sandbox",
        "/Library/Updates", "/Library/CoreServices", "/Library/Catacomb", "/Library/Developer/CoreSimulator"
    ]

    static let protectedHomeChildren: Set<String> = [
        "Library", "Applications", "Desktop", "Documents",
        "Downloads", "Movies", "Music", "Pictures", "Public", "Sites"
    ]

    static let appleBundledApps: Set<String> = [
        "Safari.app", "Mail.app", "Music.app", "TV.app", "News.app",
        "Photos.app", "FaceTime.app", "Maps.app", "Messages.app",
        "Calendar.app", "Reminders.app", "Notes.app", "Stocks.app",
        "Voice Memos.app", "Home.app", "Books.app", "Podcasts.app",
        "Photo Booth.app", "QuickTime Player.app", "Preview.app",
        "TextEdit.app", "Calculator.app", "Dictionary.app",
        "Stickies.app", "Image Capture.app", "Automator.app",
        "Font Book.app", "Chess.app", "Activity Monitor.app",
        "Console.app", "System Information.app", "Terminal.app",
        "Disk Utility.app", "AirPort Utility.app",
        "Bluetooth File Exchange.app", "Audio MIDI Setup.app",
        "Boot Camp Assistant.app", "ColorSync Utility.app",
        "Digital Color Meter.app", "Grapher.app", "Keychain Access.app",
        "Screenshot.app", "Screen Sharing.app", "Script Editor.app",
        "System Preferences.app", "System Settings.app", "Find My.app",
        "Freeform.app", "Shortcuts.app", "Clock.app", "Weather.app",
        "Passwords.app", "Image Playground.app", "iPhone Mirroring.app", "Tips.app",
        "Migration Assistant.app", "Siri.app", "Mission Control.app", "Launchpad.app",
        "App Store.app", "Contacts.app", "Journal.app", "Games.app", "Phone.app", "Utilities"
    ]
}

// MARK: - iPhone & iPad (over USB)
//
// iOS gives each app a private sandbox that no Mac app can open, so the only lever DiskScout has
// is deleting the whole app (reinstalling from the App Store starts it fresh). Deleting on the
// iPhone is permanent: there is no Trash and no Undo, so nothing here is ever rated Safe.

extension SafetyClassifier {

    /// Apps whose chats or history may exist only on the phone.
    private static let iosLocalMessagingApps: Set<String> = [
        "net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB", "org.whispersystems.signal",
        "com.viber", "com.tencent.xin", "jp.naver.line", "ch.threema.iapp", "com.kakao.talk",
    ]

    /// Two-factor code generators.
    private static let iosAuthenticatorApps: Set<String> = [
        "com.google.Authenticator", "com.microsoft.azureauthenticator", "com.authy",
        "com.lastpass.authenticator", "com.duosecurity.DuoMobile",
    ]

    static func assessIOSApp(bundleID: String, name: String, dataSize: Int64, fileSharing: Bool) -> SafetyAssessment {
        let lower = name.lowercased()
        if iosAuthenticatorApps.contains(bundleID) || lower.contains("authenticator") || lower.contains("2fa") {
            return .init(.caution, "Two-factor codes",
                         "This app may hold the only copy of the sign-in codes for some of your accounts. Deleting it can lock you out of them. Move or export your codes first.")
        }
        if lower.contains("wallet") || lower.contains("metamask") {
            return .init(.caution, "Wallet app",
                         "If this is a crypto wallet and you haven't written down its recovery phrase, deleting the app loses access to the funds for good.")
        }
        if iosLocalMessagingApps.contains(bundleID) {
            return .init(.caution, "Chats stored on the phone",
                         "Message history may live only on this iPhone. Deleting the app deletes it unless the app has made a backup (WhatsApp, for example, backs up to iCloud from Settings ▸ Chats ▸ Chat Backup).")
        }
        if fileSharing && dataSize > 50_000_000 {
            return .init(.caution, "Keeps your documents",
                         "This app stores documents on the iPhone that you can see in the Files app or in Finder. Deleting the app deletes those documents too, so copy anything you want to keep first.")
        }
        return .init(.review, "iPhone app",
                     "Deleting removes the app and everything it saved on this iPhone, and it can't be undone. Most apps keep your account online, so after reinstalling from the App Store you sign in again and the app's data starts small.")
    }

    /// In-app ways to free space without deleting the app, where they exist.
    static func iosAppTip(bundleID: String) -> String? {
        switch bundleID {
        case "net.whatsapp.WhatsApp", "net.whatsapp.WhatsAppSMB":
            return "WhatsApp ▸ Settings ▸ Storage and Data ▸ Manage Storage removes big videos and forwarded files without deleting your chats."
        case "ph.telegra.Telegraph":
            return "Telegram ▸ Settings ▸ Data and Storage ▸ Storage Usage has Clear Cache. Your chats stay in Telegram's cloud."
        case "com.spotify.client":
            return "Spotify's settings have a Storage section with Clear cache. Downloaded music is kept."
        case "com.netflix.Netflix":
            return "Downloaded shows are usually most of this. Delete the ones you've watched from Netflix's Downloads."
        case "com.google.ios.youtube":
            return "Downloaded videos live in YouTube's Downloads. The rest is cache that only reinstalling clears."
        case "com.burbn.instagram", "com.facebook.Facebook", "com.linkedin.LinkedIn":
            return "This app has no clear-cache button. Deleting and reinstalling it is the only way to shrink its data; you'll sign in again."
        case "com.zhiliaoapp.musically":
            return "TikTok's Settings has Free up space, with a Clear button for the cache."
        case "com.toyopagroup.picaboo":
            return "Snapchat's Settings has Clear Cache. Your Memories aren't affected."
        case "com.google.chrome.ios":
            return "Chrome ▸ Settings ▸ Privacy and Security ▸ Delete Browsing Data clears cached pages."
        case "com.google.Maps":
            return "Offline maps can be large. Delete regions you don't need from Offline maps in your profile menu."
        case "com.amazon.aiv.AIVApp", "com.disney.disneyplus", "com.hotstar.hotstar":
            return "Downloaded videos are usually most of this. Delete them inside the app."
        default:
            return nil
        }
    }

    /// Files in the iPhone's shared media area. DiskScout only lets you look at and copy these:
    /// they belong to Apple's apps, which keep their own databases about them.
    static func assessIOSFile(path: String, isDirectory: Bool, isLog: Bool) -> SafetyAssessment {
        if isLog { return iosCrashLogs }
        func under(_ top: String) -> Bool { path == "/" + top || path.hasPrefix("/" + top + "/") }
        if path == "/" || path.isEmpty {
            return .init(.protected, "iPhone media area", "The shared storage Apple's apps use for photos, music and books.")
        }
        if under("PhotoData") || under("MediaAnalysis") || under("CloudAssets") || under("Photos") {
            return .init(.protected, "Photos library internals",
                         "The Photos app's database, thumbnails, edits and iCloud sync state. Changing anything here can corrupt your photo library, so DiskScout only lets you look.")
        }
        if under("DCIM") {
            if path.hasSuffix(".AAE") || path.hasSuffix(".aae") {
                return .init(.review, "Photo edit", "Saved edits for the photo with the same name. Deleting the photo in the Photos app removes this too.")
            }
            return .init(.review, isDirectory ? "Camera roll folder" : "Photo or video",
                         "Part of your photo library. Delete photos in the Photos app on the iPhone so albums, edits and iCloud Photos stay in sync. Copy anything you want to keep to your Mac first.")
        }
        if under("iTunes_Control") || under("Music") || under("Podcasts") || under("Radio") {
            return .init(.caution, "Music library", "Songs and episodes the Music and Podcasts apps manage. Remove them from those apps, or from Finder ▸ your iPhone ▸ Music.")
        }
        if under("Books") {
            return .init(.caution, "Books library", "Books and PDFs the Books app manages. Remove them in the Books app so its library stays correct.")
        }
        if under("Recordings") {
            return .init(.caution, "Voice memo", "A recording from Voice Memos. Remove it in the Voice Memos app.")
        }
        if under("Downloads") {
            return .init(.review, "System downloads", "Files left by downloads iOS made itself, such as updates in progress. iOS cleans these up on its own.")
        }
        return .init(.caution, "iPhone media file", "Part of the shared media area used by Apple's apps. Manage it from the app that created it.")
    }

    /// Files in an app's shared Documents folder (apps that let Finder and the Files app see them).
    static func assessIOSAppDocument(path: String, isDirectory: Bool, kind: DeviceFileKind) -> SafetyAssessment {
        let lower = path.lowercased()
        if kind == .database || lower.contains(".sqlite") || lower.hasSuffix(".db") || lower.hasSuffix(".realm") || lower.contains("/mmkv") {
            return .init(.caution, "App database",
                         "The app's own database. Deleting it can sign you out, lose anything the app keeps only on this iPhone, or stop it working.")
        }
        if isDirectory {
            return .init(.caution, "App folder", "A folder the app keeps in its shared Documents. What's inside belongs to the app; look before removing anything.")
        }
        switch kind {
        case .photo, .screenshot, .video, .audio, .document:
            return .init(.review, "File kept by the app",
                         "Something the app saved in its Documents folder, such as a download, recording or export. Copy it to your Mac if you want it; the app can usually delete it too.")
        default:
            return .init(.caution, "App data", "A file the app uses itself. Removing it can reset settings or lose data the app needs.")
        }
    }

    static let iosCrashLogs = SafetyAssessment(.safe, "Crash & diagnostic logs",
        "Reports iOS writes when an app crashes or something goes wrong. Nothing on the iPhone uses them after they're written, so deleting them can't affect your apps or data.")
}
