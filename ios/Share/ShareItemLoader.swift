import AVFoundation
import Foundation
import ImageIO
import LinkPresentation
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

/// One attachment of the share, with the title its extension item carried (Safari puts the page title there).
struct ShareInput: @unchecked Sendable {
    let provider: NSItemProvider?
    let itemText: String?

    static func collect(from inputItems: [Any]) -> [ShareInput] {
        var inputs: [ShareInput] = []
        for case let item as NSExtensionItem in inputItems {
            let text = (item.attributedContentText?.string ?? item.attributedTitle?.string)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let providers = item.attachments ?? []
            if providers.isEmpty {
                if let text, !text.isEmpty { inputs.append(ShareInput(provider: nil, itemText: text)) }
            } else {
                inputs += providers.map { ShareInput(provider: $0, itemText: text) }
            }
        }
        return inputs
    }
}

enum ShareLoadError: LocalizedError {
    case unsupported, unreadable

    var errorDescription: String? {
        switch self {
        case .unsupported: String(localized: "Item not supported")
        case .unreadable: String(localized: "Can't read this item")
        }
    }
}

/// Turns item providers into files in the work directory. Images go straight from the provider's file to a
/// downscaled JPEG through ImageIO, so a 48 MP photo is never decoded at full size.
struct ShareItemLoader: Sendable {
    let workDirectory: URL

    func load(_ input: ShareInput, progress: @escaping @Sendable (Double) -> Void) async throws -> SharedContent {
        guard let provider = input.provider else {
            return textContent(input.itemText ?? "")
        }
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        func first(_ type: UTType) -> UTType? { types.first { $0.conforms(to: type) } }

        if let type = first(.image) {
            return .image(try await loadImage(provider, type: type, progress: progress))
        }
        if let type = first(.vCard) {
            return .file(try await loadContact(provider, type: type))
        }
        if let type = types.first(where: { $0.conforms(to: .url) && !$0.conforms(to: .fileURL) }),
           let url = try? await loadURL(provider, type: type), !url.isFileURL {
            return .link(SharedLink(url: url, title: await linkTitle(provider, url: url, fallback: input.itemText)))
        }
        if first(.plainText) != nil, let text = try? await loadString(provider) {
            return textContent(text)
        }
        if let type = first(.rtf) ?? first(.rtfd) ?? first(.flatRTFD),
           let data = try? await loadData(provider, type: type),
           let text = try? NSAttributedString(data: data, options: [:], documentAttributes: nil).string {
            return textContent(text)
        }
        if let type = types.first(where: { $0.conforms(to: .data) }) ?? types.first(where: { !$0.conforms(to: .url) }) {
            return .file(try await loadFile(provider, type: type, progress: progress))
        }
        if first(.fileURL) != nil, let url = try? await loadURL(provider, type: .fileURL), url.isFileURL {
            return .file(try await copySecurityScoped(url))
        }
        throw ShareLoadError.unsupported
    }

    // MARK: Images

    private func loadImage(_ provider: NSItemProvider, type: UTType, progress: @escaping @Sendable (Double) -> Void) async throws -> SharedImage {
        let destination = try newFile(named: "\(UUID().uuidString).jpg")
        if (try? await withFileRepresentation(provider, type: type, progress: progress, body: { url throws -> Bool in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShareLoadError.unreadable }
            try ImageTranscoder.writeJPEG(from: source, to: destination)
            return true
        })) != nil {
            return try ImageTranscoder.describe(destination)
        }
        // Screenshots edited in the markup sheet and some apps only provide in-memory data or a UIImage.
        if let data = try? await loadData(provider, type: type),
           let source = CGImageSourceCreateWithData(data as CFData, nil) {
            try ImageTranscoder.writeJPEG(from: source, to: destination)
            return try ImageTranscoder.describe(destination)
        }
        let image = try await loadImageObject(provider)
        guard let data = image.jpegData(compressionQuality: 1), let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ShareLoadError.unreadable
        }
        try ImageTranscoder.writeJPEG(from: source, to: destination)
        return try ImageTranscoder.describe(destination)
    }

    // MARK: Files

    private func loadFile(_ provider: NSItemProvider, type: UTType, progress: @escaping @Sendable (Double) -> Void) async throws -> SharedFile {
        let suggested = provider.suggestedName
        let directory = try newDirectory()
        let (url, size, name) = try await withFileRepresentation(provider, type: type, progress: progress) { source -> (URL?, Int, String) in
            let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let name = Self.fileName(suggested: suggested, source: source, type: type)
            guard size <= ShareLimits.fileMaxBytes else { return (nil, size, name) }
            let destination = directory.appending(path: name)
            try FileManager.default.copyItem(at: source, to: destination)
            return (destination, size, name)
        }
        return await describeFile(url: url, name: name, size: size, fallbackType: type)
    }

    private func copySecurityScoped(_ source: URL) async throws -> SharedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let name = source.lastPathComponent
        let type = UTType(filenameExtension: source.pathExtension) ?? .data
        guard size <= ShareLimits.fileMaxBytes else {
            return await describeFile(url: nil, name: name, size: size, fallbackType: type)
        }
        let destination = try newDirectory().appending(path: name)
        try FileManager.default.copyItem(at: source, to: destination)
        return await describeFile(url: destination, name: name, size: size, fallbackType: type)
    }

    private func loadContact(_ provider: NSItemProvider, type: UTType) async throws -> SharedFile {
        let data = try await loadData(provider, type: type)
        let card = String(decoding: data, as: UTF8.self)
        let fullName = card.split(whereSeparator: \.isNewline)
            .first { $0.uppercased().hasPrefix("FN") }
            .flatMap { $0.split(separator: ":", maxSplits: 1).last }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let base = (fullName?.isEmpty == false ? fullName! : provider.suggestedName) ?? "Contact"
        let name = Self.sanitized(base) + ".vcf"
        let destination = try newDirectory().appending(path: name)
        try data.write(to: destination)
        return SharedFile(fileURL: destination, name: name, mime: "text/vcard", byteCount: data.count, kind: .contact)
    }

    private func describeFile(url: URL?, name: String, size: Int, fallbackType: UTType) async -> SharedFile {
        let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? fallbackType
        let mime = type.preferredMIMEType ?? fallbackType.preferredMIMEType ?? "application/octet-stream"
        var file = SharedFile(fileURL: url, name: name, mime: mime, byteCount: size, kind: SharedFile.kind(of: type))
        guard let url else { return file }
        file.thumbnail = await Self.thumbnail(of: url)
        if file.kind == .video || file.kind == .audio,
           let duration = try? await AVURLAsset(url: url).load(.duration), duration.isNumeric {
            file.duration = duration.seconds
        }
        return file
    }

    static func thumbnail(of url: URL) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 240, height: 240), scale: 2, representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
    }

    // MARK: Text and links

    private func textContent(_ text: String) -> SharedContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host() != nil {
            return .link(SharedLink(url: url, title: nil))
        }
        let fileName = String(localized: "Shared text.txt")
        if trimmed.count > ShareLimits.inlineTextMaxCharacters,
           let destination = try? newDirectory().appending(path: fileName),
           (try? Data(trimmed.utf8).write(to: destination)) != nil {
            return .file(SharedFile(
                fileURL: destination, name: fileName, mime: "text/plain",
                byteCount: trimmed.utf8.count, kind: .text
            ))
        }
        return .text(trimmed)
    }

    /// Title from the LinkPresentation metadata the source app attached, else the extension item's text.
    private func linkTitle(_ provider: NSItemProvider, url: URL, fallback: String?) async -> String? {
        if let metadataType = provider.registeredTypeIdentifiers.first(where: { $0.localizedCaseInsensitiveContains("linkpresentation") }),
           let type = UTType(metadataType),
           let data = try? await loadData(provider, type: type),
           let metadata = try? NSKeyedUnarchiver.unarchivedObject(ofClass: LPLinkMetadata.self, from: data),
           let title = metadata.title, !title.isEmpty {
            return title
        }
        guard let fallback, !fallback.isEmpty, fallback != url.absoluteString else { return nil }
        return fallback
    }

    // MARK: Provider bridges

    private func withFileRepresentation<Result: Sendable>(
        _ provider: NSItemProvider, type: UTType,
        progress: @escaping @Sendable (Double) -> Void,
        body: @escaping @Sendable (URL) throws -> Result
    ) async throws -> Result {
        let observer = ProgressObserver(progress)
        defer { observer.invalidate() }
        return try await withCheckedThrowingContinuation { continuation in
            // The URL is only valid inside this handler: everything that reads it happens here.
            let task = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else {
                    continuation.resume(throwing: error ?? ShareLoadError.unreadable)
                    return
                }
                continuation.resume(with: Swift.Result { try body(url) })
            }
            observer.observe(task)
        }
    }

    private func loadData(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? ShareLoadError.unreadable) }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider, type: UTType) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let url { continuation.resume(returning: url) } else { continuation.resume(throwing: error ?? ShareLoadError.unreadable) }
            }
        }
    }

    private func loadString(_ provider: NSItemProvider) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: String.self) { text, error in
                if let text { continuation.resume(returning: text) } else { continuation.resume(throwing: error ?? ShareLoadError.unreadable) }
            }
        }
    }

    private func loadImageObject(_ provider: NSItemProvider) async throws -> UIImage {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadObject(ofClass: UIImage.self) { object, error in
                if let image = object as? UIImage { continuation.resume(returning: image) } else { continuation.resume(throwing: error ?? ShareLoadError.unreadable) }
            }
        }
    }

    // MARK: Work directory

    private func newDirectory() throws -> URL {
        let directory = workDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func newFile(named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        return workDirectory.appending(path: name)
    }

    private static func fileName(suggested: String?, source: URL, type: UTType) -> String {
        let fromSource = source.lastPathComponent
        var name = suggested.map(sanitized) ?? fromSource
        if name.isEmpty { name = fromSource }
        if (name as NSString).pathExtension.isEmpty {
            let ext = source.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "") : source.pathExtension
            if !ext.isEmpty { name += ".\(ext)" }
        }
        return name
    }

    private static func sanitized(_ name: String) -> String {
        name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Forwards an item provider's loading progress; the KVO token is kept until the load ends.
private final class ProgressObserver: @unchecked Sendable {
    private let lock = NSLock()
    private var observation: NSKeyValueObservation?
    private let handler: @Sendable (Double) -> Void

    init(_ handler: @escaping @Sendable (Double) -> Void) { self.handler = handler }

    func observe(_ progress: Progress) {
        let handler = handler
        let token = progress.observe(\.fractionCompleted, options: [.initial, .new]) { progress, _ in
            handler(progress.fractionCompleted)
        }
        lock.withLock { observation = token }
    }

    func invalidate() {
        lock.withLock {
            observation?.invalidate()
            observation = nil
        }
    }
}

enum ImageTranscoder {
    static func writeJPEG(from source: CGImageSource, to destination: URL) throws {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: ShareLimits.imageMaxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ShareLoadError.unreadable
        }
        var quality = 0.82
        repeat {
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
                throw ShareLoadError.unreadable
            }
            CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
            guard CGImageDestinationFinalize(output) else { throw ShareLoadError.unreadable }
            quality -= 0.2
        } while fileSize(destination) > ShareLimits.imageMaxBytes && quality > 0.2
    }

    static func describe(_ url: URL) throws -> SharedImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ShareLoadError.unreadable }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
        ]
        let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary).map { UIImage(cgImage: $0) }
        return SharedImage(fileURL: url, byteCount: fileSize(url), pixelSize: CGSize(width: width, height: height), thumbnail: thumbnail)
    }

    // Not resourceValues: they are cached per URL value and the file is rewritten in the quality loop.
    private static func fileSize(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
    }
}
