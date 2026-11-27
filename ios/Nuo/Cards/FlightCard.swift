import SwiftUI

struct FlightCard: View {
    let payload: FlightPayload

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            Kicker(text: kicker)
            HStack(alignment: .center, spacing: Spacing.xs) {
                endpoint(code: payload.fromCode, city: payload.fromCity, time: payload.departure, terminal: payload.departureTerminal, alignment: .leading)
                FlightPath().frame(maxWidth: .infinity).frame(height: 20)
                endpoint(code: payload.toCode, city: payload.toCity, time: payload.arrival, terminal: payload.arrivalTerminal, alignment: .trailing)
            }
            let tiles = factTiles
            if !tiles.isEmpty {
                HStack(spacing: Spacing.xs) {
                    ForEach(tiles, id: \.label) { tile in
                        VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                            Text(tile.label).font(.caption2).foregroundStyle(Color.text2)
                            Text(tile.value)
                                .font(.headline)
                                .foregroundStyle(tile.tint ?? Color.ink)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, Spacing.xs)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
                    }
                }
            }
            if !payload.actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xs) {
                        ForEach(payload.actions, id: \.self) { CardActionButton(action: $0) }
                    }
                }
                .scrollClipDisabled()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var kicker: String {
        var parts = [String(localized: "Flight")]
        if let number = payload.number { parts.append(number) }
        if let date = payload.date { parts.append(date) }
        return parts.joined(separator: " · ")
    }

    private func endpoint(code: String, city: String?, time: String?, terminal: String?, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: Spacing.xxs / 2) {
            Text(code).font(.system(.largeTitle, design: .default, weight: .bold)).tracking(-0.5).foregroundStyle(Color.ink)
            let detail = [time, terminal].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            if !detail.isEmpty {
                Text(detail).font(.caption.weight(.medium)).foregroundStyle(Color.text2)
            }
            if let city {
                Text(city).font(.caption2).foregroundStyle(Color.text3).lineLimit(1)
            }
        }
        .fixedSize()
    }

    private struct Tile { let label: String; let value: String; var tint: Color? }

    private var factTiles: [Tile] {
        var tiles: [Tile] = []
        if let gate = payload.gate, !gate.isEmpty { tiles.append(Tile(label: String(localized: "Gate"), value: gate)) }
        if let seats = payload.seats, !seats.isEmpty { tiles.append(Tile(label: String(localized: "Seats"), value: seats)) }
        if let status = payload.status, !status.isEmpty { tiles.append(Tile(label: String(localized: "Status"), value: status, tint: statusTint)) }
        return tiles
    }

    private var statusTint: Color {
        let kind = (payload.statusKind ?? payload.status ?? "").lowercased()
        if ["delayed", "retard", "late"].contains(where: kind.contains) { return Color(hex: 0xE58A00) }
        if ["cancel", "annul"].contains(where: kind.contains) { return .bad }
        if ["on_time", "ontime", "heure", "landed", "atterri", "boarding", "embarq", "scheduled"].contains(where: kind.contains) { return .good }
        return .ink
    }
}

private struct FlightPath: View {
    var body: some View {
        ZStack {
            Line()
                .stroke(Color.line, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [5, 4]))
                .frame(height: 2)
            Image(systemName: "airplane")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.accent)
                .padding(.horizontal, Spacing.xxs)
                .background(Color.card)
        }
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

struct ImageCard: View {
    let payload: ImagePayload
    @State private var showsFull = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            RemoteImage(url: payload.url)
                .aspectRatio(payload.aspect ?? 4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
                .onTapGesture { showsFull = true }
            if let caption = payload.caption {
                Text(caption).font(.footnote).foregroundStyle(Color.text2).padding(.horizontal, CardMetrics.textInset)
            }
        }
        .fullScreenCover(isPresented: $showsFull) {
            ImageViewer(url: payload.url)
        }
    }
}

struct ImageViewer: View {
    let url: String
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            RemoteImage(url: url, contentMode: .fit)
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in withAnimation(.spring) { scale = 1 } })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white).frame(width: 44, height: 44)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .padding()
        }
    }
}

struct PhotosCard: View {
    let payload: PhotosPayload
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            if payload.title != nil || payload.subtitle != nil {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Kicker(text: String(localized: "Photos"), symbol: "photo.on.rectangle")
                    if let title = payload.title { Text(title).font(.title3.weight(.semibold)).foregroundStyle(Color.ink) }
                    if let subtitle = payload.subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Color.text2) }
                }
            }
            let shown = Array(payload.urls.prefix(9))
            let columns = Array(repeating: GridItem(.flexible(), spacing: Spacing.xxs), count: shown.count == 1 ? 1 : shown.count == 2 || shown.count == 4 ? 2 : 3)
            LazyVGrid(columns: columns, spacing: Spacing.xxs) {
                ForEach(Array(shown.enumerated()), id: \.offset) { index, url in
                    Color.clear
                        .aspectRatio(shown.count == 1 ? 4 / 3 : 1, contentMode: .fit)
                        .overlay { RemoteImage(url: url) }
                        .overlay {
                            if index == shown.count - 1, payload.urls.count > shown.count {
                                Color.black.opacity(0.45)
                                Text("+\(payload.urls.count - shown.count)").font(.title2.bold()).foregroundStyle(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
                        .onTapGesture { selected = url }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .fullScreenCover(item: Binding(get: { selected.map(IdentifiedURL.init) }, set: { selected = $0?.id })) { item in
            ImageViewer(url: item.id)
        }
    }

    private struct IdentifiedURL: Identifiable { let id: String }
}
