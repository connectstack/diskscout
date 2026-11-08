import AppKit
import SwiftUI
import Quartz
import QuickLookThumbnailing

/// Drives the system Quick Look panel for the current selection.
@MainActor
final class QuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private(set) var urls: [URL] = []
    private weak var previousFirstResponder: NSResponder?
    private let host = QuickLookHostView(frame: .zero)

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    func preview(_ urls: [URL], startingAt index: Int = 0) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        if panel.isVisible {
            panel.reloadData()
            panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
            return
        }
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        // The host must live in whichever window is asking (main window or a media gallery window).
        if host.window !== window {
            host.removeFromSuperview()
            window.contentView?.addSubview(host)
        }
        previousFirstResponder = window.firstResponder
        window.makeFirstResponder(host)
        panel.makeKeyAndOrderFront(nil)
        panel.currentPreviewItemIndex = min(max(0, index), urls.count - 1)
    }

    func toggle(_ urls: [URL], startingAt index: Int = 0) {
        if isVisible { QLPreviewPanel.shared().orderOut(nil) } else { preview(urls, startingAt: index) }
    }

    /// Call when the selection changes so an open panel follows along.
    func update(_ urls: [URL]) {
        guard isVisible else { return }
        self.urls = urls
        QLPreviewPanel.shared().reloadData()
    }

    fileprivate func panelDidEnd() {
        if let prev = previousFirstResponder, let window = host.window {
            window.makeFirstResponder(prev)
        }
    }

    // MARK: QLPreviewPanelDataSource
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        false
    }
}

/// Hidden NSView that sits in the responder chain so the Quick Look panel can find a controller.
final class QuickLookHostView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = QuickLookController.shared
        panel.delegate = QuickLookController.shared
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
        QuickLookController.shared.panelDidEnd()
    }
}

/// Async thumbnails with an in-memory cache, falling back to the Finder icon.
@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSString, NSImage>()

    init() { cache.countLimit = 2000 }

    func cached(_ url: URL, size: CGFloat) -> NSImage? {
        cache.object(forKey: key(url, size))
    }

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage {
        let k = key(url, size)
        if let hit = cache.object(forKey: k) { return hit }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size), scale: 2.0, representationTypes: .thumbnail)
        request.iconMode = false
        let image: NSImage
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = rep.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(image, forKey: k)
        return image
    }

    private func key(_ url: URL, _ size: CGFloat) -> NSString {
        "\(url.path)@\(Int(size))" as NSString
    }
}
