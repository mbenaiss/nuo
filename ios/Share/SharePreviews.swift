import SwiftUI

/// What is being shared: large photos when there are only images, otherwise a row of cards.
struct SharePreviews: View {
    let slots: [ShareModel.Slot]

    private var rowHeight: CGFloat {
        let onlyImages = slots.allSatisfy { if case let .ready(content) = $0.state { content.isImage } else { false } }
        return onlyImages ? 180 : 140
    }

    var body: some View {
        if slots.isEmpty {
            EmptyView()
        } else if slots.count == 1, case let .ready(content) = slots[0].state, !content.isImage {
            SlotView(state: slots[0].state, height: nil, fullWidth: true)
        } else if slots.count == 1 {
            SlotView(state: slots[0].state, height: 220, fullWidth: false)
                .frame(maxWidth: .infinity)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(slots) { slot in
                        SlotView(state: slot.state, height: rowHeight, fullWidth: false)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .padding(.horizontal, -20)
        }
    }
}

private extension SharedContent {
    var isImage: Bool { if case .image = self { true } else { false } }
}

private struct SlotView: View {
    let state: ShareModel.SlotState
    let height: CGFloat?
    let fullWidth: Bool

    var body: some View {
        switch state {
        case let .loading(fraction):
            LoadingTile(fraction: fraction, size: height ?? 140)
        case let .failed(message):
            FailedTile(message: message, height: height ?? 140)
        case let .ready(content):
            switch content {
            case let .image(image): ImageTile(image: image, height: height ?? 140)
            case let .file(file): FileCard(file: file, height: height, fullWidth: fullWidth)
            case let .link(link): LinkCard(link: link, height: height, fullWidth: fullWidth)
            case let .text(text): TextCard(text: text, height: height, fullWidth: fullWidth)
            }
        }
    }
}

private struct ImageTile: View {
    let image: SharedImage
    let height: CGFloat

    private var width: CGFloat {
        guard image.pixelSize.height > 0 else { return height }
        return min(max(height * image.pixelSize.width / image.pixelSize.height, height * 0.62), height * 1.5)
    }

    var body: some View {
        Group {
            if let thumbnail = image.thumbnail {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Palette.chip.overlay(Image(systemName: "photo").foregroundStyle(Palette.text3))
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.black.opacity(0.06)))
        .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
        .accessibilityLabel("Photo")
    }
}

private struct FileCard: View {
    let file: SharedFile
    let height: CGFloat?
    let fullWidth: Bool

    var body: some View {
        if file.kind == .video, let thumbnail = file.thumbnail, let height {
            videoTile(thumbnail, height: height)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .center, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(file.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                Text(details)
                    .font(.caption)
                    .foregroundStyle(file.isTooLarge ? Palette.bad : Palette.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(width: fullWidth ? nil : 210, height: height, alignment: .leading)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .shareCard(radius: 20)
        .opacity(file.isTooLarge ? 0.75 : 1)
    }

    private var icon: some View {
        Group {
            if let thumbnail = file.thumbnail, file.kind != .contact {
                Image(uiImage: thumbnail).resizable().scaledToFill()
            } else {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Palette.accentInk)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Palette.accentSoft)
            }
        }
        .frame(width: 44, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
    }

    private func videoTile(_ thumbnail: UIImage, height: CGFloat) -> some View {
        Image(uiImage: thumbnail)
            .resizable()
            .scaledToFill()
            .frame(width: height * 0.8, height: height)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(.black.opacity(0.35), in: Circle())
            }
            .overlay(alignment: .bottomLeading) {
                Text(file.isTooLarge ? String(localized: "Too large") : (file.duration.map(ShareFormat.duration) ?? ShareFormat.bytes(file.byteCount)))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(file.isTooLarge ? Palette.bad : .black.opacity(0.45), in: Capsule())
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
    }

    private var symbol: String {
        switch file.kind {
        case .video: "film"
        case .audio: "waveform"
        case .pdf: "doc.richtext"
        case .contact: "person.crop.circle"
        case .archive: "doc.zipper"
        case .text: "doc.text"
        case .document: "doc"
        }
    }

    private var details: String {
        if file.isTooLarge { return String(localized: "\(ShareFormat.bytes(file.byteCount)) · too large (50 MB max)") }
        let label: String = switch file.kind {
        case .contact: String(localized: "Contact card")
        case .pdf: "PDF"
        case .audio: file.duration.map { String(localized: "Audio · \(ShareFormat.duration($0))") } ?? String(localized: "Audio")
        case .video: file.duration.map { String(localized: "Video · \(ShareFormat.duration($0))") } ?? String(localized: "Video")
        default: (file.name as NSString).pathExtension.uppercased().nilIfEmpty ?? String(localized: "File")
        }
        return "\(label) · \(ShareFormat.bytes(file.byteCount))"
    }
}

private struct LinkCard: View {
    let link: SharedLink
    let height: CGFloat?
    let fullWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(String(link.domain.prefix(1)).uppercased())
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.accentInk)
                    .frame(width: 26, height: 26)
                    .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(link.domain)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Palette.text2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "link")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.text3)
            }
            Spacer(minLength: 12)
            Text(link.title ?? link.url.absoluteString)
                .font(.body.weight(.semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(fullWidth ? 3 : 2)
                .multilineTextAlignment(.leading)
            if link.title != nil {
                Text(link.url.absoluteString)
                    .font(.caption)
                    .foregroundStyle(Palette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(width: fullWidth ? nil : 260, height: height, alignment: .topLeading)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .shareCard(radius: 20)
    }
}

private struct TextCard: View {
    let text: String
    let height: CGFloat?
    let fullWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "text.quote")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accentInk)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Palette.ink)
                .lineLimit(fullWidth ? 6 : 4)
            Spacer(minLength: 0)
            Text("\(text.count) characters")
                .font(.caption2)
                .foregroundStyle(Palette.text3)
        }
        .padding(14)
        .frame(width: fullWidth ? nil : 240, height: height, alignment: .topLeading)
        .frame(maxWidth: fullWidth ? .infinity : nil, alignment: .leading)
        .shareCard(radius: 20)
    }
}

private struct LoadingTile: View {
    let fraction: Double
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(Palette.line, lineWidth: 4)
            Circle()
                .trim(from: 0, to: max(0.04, fraction))
                .stroke(Palette.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
        .frame(width: 30, height: 30)
        .frame(width: size, height: size)
        .shareCard(radius: 20)
        .accessibilityLabel("Loading")
    }
}

private struct FailedTile: View {
    let message: String
    let height: CGFloat

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.bad)
            Text(message)
                .font(.caption)
                .foregroundStyle(Palette.text2)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(width: 150, height: height)
        .shareCard(radius: 20)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
