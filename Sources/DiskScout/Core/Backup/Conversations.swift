import Foundation
import SwiftUI

// One model for every messaging service, so the viewer, search and export are written once.

enum MessagingService: String, CaseIterable, Identifiable, Sendable {
    case whatsapp = "WhatsApp"
    case messages = "Messages"
    case instagram = "Instagram"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .whatsapp: return "bubble.left.and.bubble.right.fill"
        case .messages: return "message.fill"
        case .instagram: return "camera.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .whatsapp: return Color(red: 0.15, green: 0.68, blue: 0.42)
        case .messages: return Color(red: 0.20, green: 0.55, blue: 1.0)
        case .instagram: return Color(red: 0.86, green: 0.27, blue: 0.55)
        }
    }
}

struct ChatThread: Identifiable, Hashable, Sendable {
    let id: String
    let service: MessagingService
    let title: String
    /// A phone number, handle or participant list under the title.
    let detail: String?
    let isGroup: Bool
    let lastDate: Date?
    var messageCount: Int
    var mediaCount: Int
    var mediaBytes: Int64
    var archived = false
}

struct ChatAttachment: Hashable, Sendable {
    enum Kind: String, Sendable {
        case image, video, audio, document, contact, location, sticker, link, other

        var label: String {
            switch self {
            case .image: return "Photo"
            case .video: return "Video"
            case .audio: return "Audio"
            case .document: return "Document"
            case .contact: return "Contact"
            case .location: return "Location"
            case .sticker: return "Sticker"
            case .link: return "Link"
            case .other: return "Attachment"
            }
        }

        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .video: return "video"
            case .audio: return "waveform"
            case .document: return "doc"
            case .contact: return "person.crop.circle"
            case .location: return "mappin.and.ellipse"
            case .sticker: return "face.smiling"
            case .link: return "link"
            case .other: return "paperclip"
            }
        }

        init(mimeType: String?, fileName: String?) {
            let mime = mimeType?.lowercased() ?? ""
            let ext = ((fileName ?? "") as NSString).pathExtension.lowercased()
            if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "heic", "gif", "webp"].contains(ext) { self = .image }
            else if mime.hasPrefix("video/") || ["mov", "mp4", "m4v"].contains(ext) { self = .video }
            else if mime.hasPrefix("audio/") || ["m4a", "caf", "amr", "mp3", "opus", "aac"].contains(ext) { self = .audio }
            else if mime.contains("vcard") || ext == "vcf" { self = .contact }
            else if mime.isEmpty && ext.isEmpty { self = .other }
            else { self = .document }
        }
    }

    let kind: Kind
    let title: String?
    let size: Int64
    /// What the store needs to find the file; nil when the file isn't available.
    let locator: String?
}

struct ChatMessage: Identifiable, Hashable, Sendable {
    let id: String
    let date: Date?
    let fromMe: Bool
    let sender: String?
    let text: String?
    /// Group events ("Alex left"), not something a person typed.
    let isSystem: Bool
    let attachments: [ChatAttachment]
}

/// A place conversations can be read from (a WhatsApp database, the Messages database, an
/// Instagram export). Implementations are read-only and safe to call from a background thread.
protocol ConversationStore: AnyObject, Sendable {
    var service: MessagingService { get }
    func threads() throws -> [ChatThread]
    /// The latest `limit` messages of a thread, oldest first.
    func messages(in thread: String, limit: Int) throws -> [ChatMessage]
    /// Every message that has text, for the search index.
    func forEachText(_ body: (_ thread: String, _ messageID: String, _ date: Date?, _ sender: String?, _ text: String) -> Void) throws
    /// A readable file for an attachment, or nil if it isn't stored here.
    func file(for attachment: ChatAttachment) throws -> URL?
}

enum ChatTranscript {
    static func text(thread: ChatThread, messages: [ChatMessage]) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        var lines = ["\(thread.title) — \(thread.service.rawValue) conversation exported by DiskScout", ""]
        for m in messages {
            let when = m.date.map { f.string(from: $0) } ?? "?"
            var body = m.text ?? ""
            for a in m.attachments {
                let size = a.size > 0 ? " · " + a.size.bytesString : ""
                let tag = "<\(a.kind.label)\(a.title.map { ": " + $0 } ?? "")\(size)>"
                body = body.isEmpty ? tag : body + " " + tag
            }
            lines.append(m.isSystem ? "[\(when)] \(body)" : "[\(when)] \(m.fromMe ? "Me" : (m.sender ?? thread.title)): \(body)")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

// MARK: - WhatsApp

/// Adapts `WhatsAppReader` to the shared model.
final class WhatsAppStore: ConversationStore, @unchecked Sendable {
    let service = MessagingService.whatsapp
    let reader: WhatsAppReader
    private let media: @Sendable (String) throws -> URL?

    init(reader: WhatsAppReader, media: @escaping @Sendable (String) throws -> URL?) {
        self.reader = reader
        self.media = media
    }

    func threads() throws -> [ChatThread] {
        try reader.chats().map { c in
            ChatThread(id: String(c.id), service: .whatsapp, title: c.name, detail: c.isGroup ? nil : WhatsAppReader.readable(jid: c.jid),
                       isGroup: c.isGroup, lastDate: c.lastMessageDate, messageCount: c.messageCount,
                       mediaCount: c.mediaCount, mediaBytes: c.mediaBytes, archived: c.archived)
        }
    }

    func messages(in thread: String, limit: Int) throws -> [ChatMessage] {
        guard let id = Int64(thread) else { return [] }
        return try reader.messages(in: id, limit: limit).map(Self.convert)
    }

    static func convert(_ m: WAMessage) -> ChatMessage {
        var attachments: [ChatAttachment] = []
        if m.kind != .text && m.kind != .system {
            let kind: ChatAttachment.Kind
            switch m.kind {
            case .image: kind = .image
            case .video, .gif: kind = .video
            case .audio: kind = .audio
            case .contact: kind = .contact
            case .location: kind = .location
            case .document: kind = .document
            case .sticker: kind = .sticker
            case .link: kind = .link
            default: kind = .other
            }
            attachments = [ChatAttachment(kind: kind, title: m.mediaTitle, size: m.mediaSize, locator: m.mediaPath)]
        }
        return ChatMessage(id: String(m.id), date: m.date, fromMe: m.fromMe, sender: m.sender, text: m.text, isSystem: m.kind == .system, attachments: attachments)
    }

    func forEachText(_ body: (String, String, Date?, String?, String) -> Void) throws {
        try reader.forEachText { chat, id, date, sender, text in body(String(chat), String(id), date, sender, text) }
    }

    func file(for attachment: ChatAttachment) throws -> URL? {
        try attachment.locator.flatMap(media)
    }
}
