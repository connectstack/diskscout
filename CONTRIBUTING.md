# Contributing to DiskScout

Thanks for helping. DiskScout deletes people's files and reads their messages, so the bar is simple: **never surprise anyone, and never leak anything.** Everything below follows from that.

## Getting set up

You need macOS 14 or later and Xcode 15 or later (Swift 5.9).

```bash
git clone https://github.com/connectstack/diskscout.git
```

```bash
cd diskscout && swift run DiskScout --sample-home --sample-device
```

Or open `Package.swift` in Xcode and press ⌘R. Run the tests with:

```bash
swift test
```

### Work on invented data

Debug builds can run without touching your own files, phone or messages. Use these whenever you work on a screen, take a screenshot or record a bug:

- `--sample-home`: an invented home folder (caches, Xcode junk, leftovers, projects, photos). It's built in `~/Library/Caches/DiskScout-sample` from APFS clones, so it costs about 1 GB of real disk. Delete that folder whenever you like.
- `--sample-device`: an invented iPhone instead of real ones.
- `--demo-mac-data`, `--demo-backup`, `--demo-instagram-html`: invented chats, notes, calls, Safari data, an encrypted backup (password `sample-password`) and an Instagram export.

The full list is in the README under [Sample data](README.md#sample-data). The sample builders are `SampleHome.swift`, the end of `IOSDevice.swift` and `Backup/BackupFixture.swift`. Extend them when you add a feature, so the next person can see it too.

## What to work on

- **Cleanup locations.** Know a cache, log folder or build directory DiskScout doesn't find? Add it to `CleanupScanner.swift` and give it a rating in `SafetyClassifier.swift`.
- **Safety rules.** Better reasons, apps whose data deserves Caution, false Safes. See below.
- **Bug reports** from Mac and iPhone models we haven't tried, especially with steps to reproduce.
- **Anything in the issue tracker**, or an idea you'd like to discuss first. For larger changes, open an issue before writing a lot of code.

## Safety rules

`SafetyClassifier.swift` is the heart of the app. A wrong rating can destroy someone's work, so:

1. **Every rule change needs a test** in `SafetyClassifierTests.swift` that pins the new verdict.
2. **When in doubt, it's Review.** Safe means "rebuilt automatically, deleting it only frees space". If you can't say that with confidence, it isn't Safe.
3. **Write the reason for a person**, in one plain sentence: what it is and what happens if it goes. If something rebuilds itself, say what rebuilds it.
4. **Protected means refusal.** Don't loosen a Protected rule without discussing it in an issue first.
5. Nothing is deleted without the review sheet, and Mac deletions always go to the Trash. Don't add a path around either.

## Privacy rules

- **No network requests.** DiskScout doesn't phone home, and new features shouldn't either.
- **Never open live databases.** Copy them (with their `-wal` and `-shm` files) into a private folder (mode 0700), read the copy, and delete it when you're done. Decrypted backup files and the search index must be gone after lock, quit or the next launch.
- **Only invented data in tests, fixtures, screenshots and issues.** No real names, numbers, chats or file paths from your own Mac or phone.
- Don't add logging that could write message text, contact names or file names to disk.

## iPhone code

`MobileDevice.swift` calls Apple's private MobileDevice framework through `dlsym`. Get the C signatures exactly right: one lesson learned the hard way is that `AFCFileRefRead`'s length is a 64-bit value, and passing a 32-bit one corrupted the stack and caused random crashes far from the call. Test against a real device with:

```bash
swift run DiskScout --selftest-device
```

That check never deletes anything real. It writes and removes a throwaway folder in the phone's Downloads area, and round-trips an uninstall for an app ID that can't exist.

## Pull requests

- Keep each pull request focused on one thing, and describe what changed and why.
- Match the style of the code around you. SwiftUI for views, no new dependencies without discussing them first.
- `swift test` passes, and the screens you touched look right in both light and dark mode (`--appearance light`).
- Add or update tests for behaviour changes, and screenshots (with sample data) for visible ones.

## Reporting bugs

Open an issue with what you did, what you expected, and what happened, plus your macOS version and, for iPhone problems, the device model and iOS version. Please blur or leave out anything personal in screenshots.

For a security problem, such as a way DiskScout could delete or expose data it shouldn't, please don't open a public issue. Use **Report a vulnerability** on the repository's Security tab.

## License

By contributing, you agree that your contributions are licensed under the [Apache License 2.0](LICENSE), the same as the rest of the project.
