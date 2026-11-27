import Foundation
import UIKit
import UniformTypeIdentifiers

enum ShareLimits {
    /// Gateway limits (docs/protocol.md, "Attachments").
    static let imageMaxBytes = 10 * 1024 * 1024
    static let fileMaxBytes = 50 * 1024 * 1024
    static let imageMaxPixels = 2048
    /// Longer shared text goes as a .txt attachment instead of bloating the prompt.
    static let inlineTextMaxCharacters = 20_000
}

/// An image re-encoded as JPEG (at most 2048 px on its long edge) in the extension's work directory.
struct SharedImage: Sendable {
    let fileURL: URL
    let byteCount: Int
    let pixelSize: CGSize
    let thumbnail: UIImage?
}

struct SharedFile: Sendable {
    enum Kind: Sendable { case video, audio, pdf, contact, archive, text, document }

    /// Nil when the file is over the limit: it is never copied.
    let fileURL: URL?
    let name: String
    let mime: String
    let byteCount: Int
    let kind: Kind
    var thumbnail: UIImage?
    var duration: TimeInterval?

    var isTooLarge: Bool { byteCount > ShareLimits.fileMaxBytes }

    static func kind(of type: UTType) -> Kind {
        if type.conforms(to: .audiovisualContent) && !type.conforms(to: .audio) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .vCard) || type.conforms(to: .contact) { return .contact }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) { return .text }
        return .document
    }
}

struct SharedLink: Sendable {
    let url: URL
    let title: String?

    var domain: String {
        let host = url.host() ?? url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}

enum SharedContent: Sendable {
    case image(SharedImage)
    case file(SharedFile)
    case link(SharedLink)
    case text(String)
}

enum ShareFormat {
    static func bytes(_ count: Int) -> String {
        count.formatted(.byteCount(style: .file).locale(.current))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "2 photos", "1 link · 1 file"…
    static func summary(of contents: [SharedContent]) -> String {
        var photos = 0, videos = 0, files = 0, links = 0, texts = 0, contacts = 0
        for content in contents {
            switch content {
            case .image: photos += 1
            case let .file(file):
                switch file.kind {
                case .video: videos += 1
                case .contact: contacts += 1
                default: files += 1
                }
            case .link: links += 1
            case .text: texts += 1
            }
        }
        let parts: [(Int, String)] = [
            (photos, String(localized: "\(photos) photos")), (videos, String(localized: "\(videos) videos")),
            (files, String(localized: "\(files) files")), (links, String(localized: "\(links) links")),
            (texts, String(localized: "\(texts) texts")), (contacts, String(localized: "\(contacts) contacts")),
        ]
        return parts.filter { $0.0 > 0 }.map(\.1).joined(separator: " · ")
    }
}
