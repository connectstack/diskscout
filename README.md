# DiskScout

**Know what's safe to delete.**

DiskScout is a macOS disk-cleanup app built around the one question every other cleaner skips: *is it safe to remove this?* Every file and folder gets a safety rating and a plain-English explanation, so people stop guessing and stop breaking things.

![Safety levels](docs/safety-levels.svg)

| Level | Meaning | What DiskScout does |
|---|---|---|
| 🟢 **Safe** | Caches, logs, build products, package caches, device symbols, window state. Rebuilt automatically. | One click selects all of it. |
| 🔵 **Review** | Personal files, installers, archives, iPhone backups, leftovers from uninstalled apps. Only the user can judge. | Preview + explanation, normal confirmation. |
| 🟠 **Caution** | App data: Application Support, Containers, Preferences, iCloud Drive, Mail, Chrome profile… | Extra acknowledgement in the review sheet. |
| 🔴 **Protected** | `/System`, `/usr`, Keychains, SSH keys, home-folder structure, Library root… | Refuses to delete. |

The rules live in one auditable file: [SafetyClassifier.swift](Sources/DiskScout/Core/SafetyClassifier.swift). Tests in [Tests/DiskScoutTests](Tests/DiskScoutTests) pin the important verdicts.

## Features

- **Smart Clean** – sizes known junk locations in parallel (app & browser caches, logs, Xcode DerivedData / DeviceSupport / simulators, npm/Homebrew/pip/Gradle/Cargo/Docker caches, Mail attachment copies, iOS backups, installers in Downloads, saved window state) and **finds leftovers from uninstalled apps** by matching reverse-DNS folders against installed bundle IDs. "Select everything safe" → "Review & Clean".
- **Browse** – fast parallel scanner (fans out across cores near the top of the tree, streams top-level results while scanning), sortable list with share bars, safety badges, filter field, multi-select, keyboard navigation (Space = Quick Look, ⌘⌫ = Trash, ⌘↑ = up).
- **Treemap** – nested, animated squarified treemap coloured by safety, file type or size.
- **Duplicates** – size-bucketed SHA-256 duplicate finder with "keep newest / oldest / shortest path" auto-selection.
- **Large & Old** – biggest files, or files unused for N months, with a "personal files only" filter.
- **Inspector** – Quick Look thumbnail, kind, dates, path, category and the full safety card for whatever is selected. Full Quick Look panel on Space.
- **Review sheet** – every deletion is listed with its rating and reason; Caution items need an explicit acknowledgement; protected items are skipped and say why.
- **Undo & history** – everything goes to the Trash via `FileManager.trashItem`; the toast offers Undo, and the History window can put any item back. Lifetime "freed" counter.
- **Full Disk Access** detection with a one-click path to the right Settings pane.
- **Licensing** – 14-day fully functional trial, then scanning/preview stay free and cleaning requires a key. Offline Ed25519 key validation, no server needed.

## Build & run

Requires Xcode 15+ / macOS 14+.

```bash
swift run -c release
```

or `open Package.swift` in Xcode and ⌘R. Useful launch flags: `--scan ~/Downloads --mode treemap` (modes: smart, browse, treemap, duplicates, large).

Run the tests:

```bash
swift test
```

## Ship it

### 1. Keys

The private signing key lives in `Scripts/licensing/keys/private.key` (git-ignored). **Back it up**: every issued DS1 key is useless without it. To start over, delete it and run:

```bash
swift Scripts/licensing/generate-keys.swift
```

then paste the printed public key into `LicenseManager.publicKeyHex`.

The app accepts two kinds of key:

- **Gumroad license keys** (`XXXXXXXX-XXXXXXXX-XXXXXXXX-XXXXXXXX`). Gumroad generates these for every sale when “Generate a unique license key per sale” is on in the product settings. DiskScout checks the key once against Gumroad's licence API, caches the result, and quietly re-checks about weekly so refunds revoke access. This needs the product ID baked in at build time (below).
- **DS1 keys**, signed offline with your private key. Use these for Patreon supporters, giveaways and support cases:

```bash
swift Scripts/licensing/sign-license.swift patron@example.com
```

```bash
swift Scripts/licensing/sign-license.swift patron@example.com 2027-12-31
```

### 2. Build the app bundle and DMG

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" PURCHASE_URL="https://yourname.gumroad.com/l/diskscout" GUMROAD_PRODUCT_ID="<product id from Gumroad>" Scripts/build-app.sh
```

```bash
SIGN_ID="Developer ID Application: Your Name (TEAMID)" Scripts/make-dmg.sh
```

`build-app.sh` compiles a release binary, writes `Info.plist` (bundle ID, version, usage descriptions, store URL, Gumroad product ID), renders the app icon, and codesigns with the hardened runtime. `make-dmg.sh` produces `dist/DiskScout-<version>.dmg` plus a `.sha256` file. Bump `VERSION=` for each release.

Notarize before publishing, or macOS 15+ will refuse to open the app for your customers. One-time setup with an app-specific password from appleid.apple.com:

```bash
xcrun notarytool store-credentials "notary" --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
```

Then for every release:

```bash
xcrun notarytool submit dist/DiskScout-2.0.0.dmg --keychain-profile "notary" --wait && xcrun stapler staple dist/DiskScout-2.0.0.dmg
```

Upload the stapled DMG to Gumroad (as the product file) and to Patreon (as a post attachment or a link). Listing copy is in [docs/listing.md](docs/listing.md).

### 3. Why not the Mac App Store?

A disk cleaner needs to read `~/Library` (and ideally Full Disk Access) and move arbitrary files to the Trash. That is incompatible with App Store sandboxing, which is why every serious Mac cleaner (CleanMyMac, DaisyDisk's full version, GrandPerspective's FDA build) is sold directly. Direct sales also mean no 30% cut and you own the customer relationship. Keep the architecture; sell via your own site.

### 4. Sparkle updates (recommended next step)

Add the [Sparkle](https://sparkle-project.org) package, an `SUFeedURL` in `Info.plist`, and host an appcast. `build-app.sh` is already structured so the appcast step can be appended.

## Project layout

```
Sources/DiskScout/
  Core/
    SafetyClassifier.swift   # the rating rules — the product
    FileCategory.swift       # Apps / Documents / Photos / Developer / Caches …
    ScanEngine.swift         # parallel scanner with streaming progress
    CleanupScanner.swift     # Smart Clean categories + leftover detection
    TrashManager.swift       # trash, put back, history persistence
    LicenseManager.swift     # trial + Ed25519 license keys
    AppModel.swift           # app state, trash plans, undo, toasts
    DuplicateFinder.swift, Treemap.swift, DiskWalker.swift, QuickLook.swift, …
  Views/
    ContentView.swift, HeroCard.swift, SmartCleanView.swift, BrowseView.swift,
    TreemapView.swift, DuplicatesView.swift, FinderView.swift, InspectorView.swift,
    ReviewSheet.swift, ScanningView.swift, WelcomeView.swift, SettingsView.swift, …
Scripts/
  build-app.sh, make-dmg.sh, make-icon.swift, licensing/
Tests/DiskScoutTests/
```

## Notes

- Sizes are allocated size on disk, matching Finder's "size on disk". Hidden files are included by default (that is where developer junk hides); toggle in Settings.
- App bundles and other packages are treated as single items.
- Whole-Mac scans skip `/System/Volumes` and `/Volumes` to avoid double-counting firmlinks and external disks.
- Emptying the Trash is delegated to Finder (requires the Automation permission the first time).
