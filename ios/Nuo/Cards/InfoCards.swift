import Charts
import MapKit
import SwiftUI

struct WeatherCard: View {
    let payload: WeatherPayload

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.xs) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(payload.location).font(.headline).foregroundStyle(Color.ink)
                    if let period = payload.period { Text(period).font(.caption).foregroundStyle(Color.text2) }
                    if !payload.temperature.isEmpty {
                        Text(payload.temperature)
                            .font(.system(size: temperatureSize, weight: .light))
                            .tracking(-2)
                            .foregroundStyle(Color.ink)
                    }
                }
                Spacer(minLength: Spacing.xs)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    WeatherIcon(name: payload.symbol ?? WeatherSymbols.symbol(for: payload.condition))
                        .font(.system(size: 34))
                    if !payload.condition.isEmpty { Text(payload.condition).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink) }
                    let range = [payload.detail, highLow].compactMap { $0 }.joined(separator: " · ")
                    if !range.isEmpty { Text(range).font(.caption).foregroundStyle(Color.text2).multilineTextAlignment(.trailing) }
                }
            }

            if !payload.hours.isEmpty {
                // Spread the hours over the card when they fit, scroll otherwise.
                ViewThatFits(in: .horizontal) {
                    hours(spread: true)
                    ScrollView(.horizontal, showsIndicators: false) { hours(spread: false) }
                }
            }

            if !payload.days.isEmpty {
                let lows = payload.days.compactMap(\.low)
                let highs = payload.days.compactMap(\.high)
                let minValue = lows.min() ?? 0
                let maxValue = highs.max() ?? 1
                VStack(spacing: Spacing.sm) {
                    ForEach(Array(payload.days.enumerated()), id: \.offset) { _, day in
                        HStack(spacing: Spacing.xs) {
                            Text(day.day).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.8)
                                .frame(width: dayWidth, alignment: .leading)
                            WeatherIcon(name: day.symbol ?? "cloud.fill").frame(width: iconWidth)
                            Text(day.rain ?? "").font(.caption.monospacedDigit()).foregroundStyle(Color(hex: 0x3B82F6)).lineLimit(1)
                                .frame(width: rainWidth, alignment: .leading)
                            Text(day.low.map { "\(Int($0.rounded()))°" } ?? "").font(.subheadline.monospacedDigit()).foregroundStyle(Color.text2)
                                .frame(width: degreeWidth, alignment: .trailing)
                            TemperatureBar(low: day.low ?? minValue, high: day.high ?? maxValue, minValue: minValue, maxValue: maxValue)
                            Text(day.high.map { "\(Int($0.rounded()))°" } ?? "").font(.subheadline.weight(.medium).monospacedDigit()).foregroundStyle(Color.ink)
                                .frame(width: degreeWidth, alignment: .trailing)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    @ScaledMetric(relativeTo: .largeTitle) private var temperatureSize: CGFloat = 56
    @ScaledMetric(relativeTo: .subheadline) private var dayWidth: CGFloat = 64
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth: CGFloat = 24
    @ScaledMetric(relativeTo: .caption) private var rainWidth: CGFloat = 36
    @ScaledMetric(relativeTo: .subheadline) private var degreeWidth: CGFloat = 32

    private func hours(spread: Bool) -> some View {
        HStack(spacing: spread ? 0 : Spacing.lg) {
            ForEach(Array(payload.hours.enumerated()), id: \.offset) { _, hour in
                VStack(spacing: Spacing.xs) {
                    Text(hour.time).font(.caption.monospacedDigit()).foregroundStyle(Color.text2)
                    WeatherIcon(name: hour.symbol ?? WeatherSymbols.symbol(for: payload.condition))
                    Text(hour.temperature).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
                }
                .fixedSize()
                .frame(maxWidth: spread ? .infinity : nil)
            }
        }
    }

    private var highLow: String? {
        guard payload.high != nil || payload.low != nil else { return nil }
        return String(localized: "H:\(payload.high ?? "–") L:\(payload.low ?? "–")")
    }
}

private struct TemperatureBar: View {
    let low: Double
    let high: Double
    let minValue: Double
    let maxValue: Double

    var body: some View {
        GeometryReader { geo in
            let span = max(maxValue - minValue, 1)
            let start = (low - minValue) / span * geo.size.width
            let end = (high - minValue) / span * geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.chip)
                Capsule()
                    .fill(LinearGradient(colors: [Color(hex: 0x7CC4FF), Color.accent2, Color.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, end - start))
                    .offset(x: start)
            }
        }
        .frame(height: 5)
    }
}

/// Multicolor SF weather symbols are white where there are clouds, invisible on a white card.
private struct WeatherIcon: View {
    let name: String

    var body: some View {
        if name.hasPrefix("sun") || name.hasPrefix("moon") {
            Image(systemName: name).foregroundStyle(Color(hex: 0xFFB020))
        } else {
            Image(systemName: name)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.text2, name.contains("sun") ? Color(hex: 0xFFB020) : Color(hex: 0x4A9DF0), Color(hex: 0xFFB020))
        }
    }
}

struct PlaceCard: View {
    let payload: PlacePayload

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mapHeader
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Kicker(text: String(localized: "Maps"), symbol: "map")
                HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(payload.name).font(.headline).foregroundStyle(Color.ink)
                        let secondary = [payload.category, payload.distance].compactMap { $0 }.joined(separator: " · ")
                        if !secondary.isEmpty { Text(secondary).font(.subheadline).foregroundStyle(Color.text2) }
                    }
                    Spacer(minLength: 0)
                    if let rating = payload.rating {
                        Label(rating, systemImage: "star.fill").font(.subheadline.weight(.semibold)).foregroundStyle(Color(hex: 0xF5A623))
                    }
                }
                if let address = payload.address {
                    Label(address, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(Color.text2)
                }
                if let open = payload.openStatus {
                    Text(open).font(.subheadline.weight(.medium)).foregroundStyle(Color.good)
                }
                HStack(spacing: Spacing.xs) {
                    if let url = mapsURL {
                        Link(destination: url) { ChipButtonLabel(title: String(localized: "Open in Maps"), symbol: "map", prominent: true) }
                    }
                    if let phone = payload.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                        Link(destination: url) { ChipButtonLabel(title: String(localized: "Call"), symbol: "phone") }
                    }
                }
                .padding(.top, Spacing.xxs)
            }
            .padding(CardMetrics.padding)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.card)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }

    @ViewBuilder
    private var mapHeader: some View {
        if let latitude = payload.latitude, let longitude = payload.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            Map(initialPosition: .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: 600, longitudinalMeters: 600)), interactionModes: []) {
                Marker(payload.name, coordinate: coordinate).tint(Color.accent)
            }
            .frame(height: 140)
            .allowsHitTesting(false)
        }
    }

    private var mapsURL: URL? {
        if let raw = payload.url, let url = URL(string: raw) { return url }
        if let latitude = payload.latitude, let longitude = payload.longitude {
            return URL(string: "https://maps.apple.com/?ll=\(latitude),\(longitude)&q=\(payload.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")
        }
        let query = payload.query ?? payload.address ?? payload.name
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return URL(string: "https://maps.apple.com/?q=\(encoded)")
    }
}

struct RouteCard: View {
    let payload: RoutePayload

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            Kicker(text: String(localized: "Directions"), symbol: transportSymbol)
            HStack(alignment: .top, spacing: Spacing.sm) {
                VStack(spacing: Spacing.xxs) {
                    Circle().fill(Color.accent).frame(width: 9, height: 9)
                    Rectangle().fill(Color.line).frame(width: 2, height: 20)
                    Image(systemName: "mappin.circle.fill").foregroundStyle(Color.ink)
                }
                .padding(.top, Spacing.xxs)
                VStack(alignment: .leading, spacing: Spacing.md) {
                    Text(payload.from).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                    Text(payload.to).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: Spacing.xxs) {
                    if let duration = payload.duration { Text(duration).font(.title3.bold()).foregroundStyle(Color.ink) }
                    if let distance = payload.distance { Text(distance).font(.caption).foregroundStyle(Color.text2) }
                }
            }
            if let url = payload.mapsURL {
                Link(destination: url) { ChipButtonLabel(title: String(localized: "Directions"), symbol: "location.fill", prominent: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var transportSymbol: String {
        switch payload.transport {
        case "walking": "figure.walk"
        case "transit": "tram.fill"
        case "cycling": "bicycle"
        default: "car.fill"
        }
    }
}

struct EventCard: View {
    let payload: EventPayload

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(spacing: 0) {
                Text(dayLabel).font(.caption2.weight(.bold)).tracking(0.5)
                Text(dateLabel).font(.title2.bold()).lineLimit(1)
            }
            .foregroundStyle(Color.accent)
            .frame(width: 54, height: 58)
            .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(payload.title).font(.headline).foregroundStyle(Color.ink)
                if let timeText { Label(timeText, systemImage: "clock").font(.subheadline).foregroundStyle(Color.text2) }
                if let location = payload.location { Label(location, systemImage: "mappin.and.ellipse").font(.subheadline).foregroundStyle(Color.text2) }
                if let join = payload.joinURL, let url = URL(string: join) {
                    Link(destination: url) { ChipButtonLabel(title: String(localized: "Join"), symbol: "video.fill", prominent: true) }.padding(.top, Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var parsedDate: Date? { payload.date.flatMap(NuoJSON.parseDate) }

    private var dayLabel: String {
        guard let date = parsedDate else { return String(localized: "CALENDAR") }
        if Calendar.current.isDateInToday(date) { return String(localized: "card.today.short", defaultValue: "TODAY") }
        return date.formatted(.dateTime.weekday(.abbreviated).locale(.current)).uppercased()
    }

    private var dateLabel: String {
        guard let date = parsedDate else { return "•" }
        return date.formatted(.dateTime.day())
    }

    private var timeText: String? {
        if payload.allDay { return String(localized: "All day") }
        guard let date = parsedDate else { return payload.date }
        let start = date.formatted(date: .omitted, time: .shortened)
        if let end = payload.endDate.flatMap(NuoJSON.parseDate) {
            return "\(start) – \(end.formatted(date: .omitted, time: .shortened))"
        }
        return start
    }
}

struct ContactCard: View {
    let payload: ContactPayload

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(initials)
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 52, height: 52)
                .background(LinearGradient(colors: [Color.accent2, Color.accent], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(payload.name).font(.headline).foregroundStyle(Color.ink)
                if let organization = payload.organization { Text(organization).font(.subheadline).foregroundStyle(Color.text2) }
                if let phone = payload.phone { Text(phone).font(.subheadline).foregroundStyle(Color.text2) }
            }
            Spacer(minLength: 0)
            if let phone = payload.phone, let url = URL(string: "tel:\(phone.filter { !$0.isWhitespace })") {
                Link(destination: url) {
                    Image(systemName: "phone.fill").foregroundStyle(Color.accent).frame(width: 40, height: 40).background(Color.accentSoft, in: Circle())
                }
            }
            if let email = payload.email, let url = URL(string: "mailto:\(email)") {
                Link(destination: url) {
                    Image(systemName: "envelope.fill").foregroundStyle(Color.accent).frame(width: 40, height: 40).background(Color.accentSoft, in: Circle())
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var initials: String {
        String(payload.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

struct StockCard: View {
    let payload: StockPayload

    var body: some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(payload.symbol).font(.headline).foregroundStyle(Color.ink)
                if let name = payload.name { Text(name).font(.caption).foregroundStyle(Color.text2) }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: Spacing.xxs) {
                if let price = payload.price { Text(price).font(.title3.bold().monospacedDigit()).foregroundStyle(Color.ink) }
                if let change = payload.change {
                    Label(change, systemImage: payload.positive ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(payload.positive ? Color.good : Color.bad)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

struct MediaCard: View {
    let payload: MediaPayload

    var body: some View {
        Group {
            if let raw = payload.url, let url = URL(string: raw) {
                Link(destination: url) { row }
            } else {
                row
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: CardMetrics.compactPadding)
    }

    private var row: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: payload.symbol ?? "link")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 42, height: 42)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(payload.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(2)
                if let subtitle = payload.subtitle { Text(subtitle).font(.caption).foregroundStyle(Color.text2).lineLimit(2) }
            }
            Spacer(minLength: 0)
            if payload.url != nil { Image(systemName: "arrow.up.right").font(.caption.weight(.bold)).foregroundStyle(Color.text3) }
        }
        .contentShape(Rectangle())
    }
}

struct NowPlayingCard: View {
    let payload: NowPlayingPayload

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Group {
                if let artwork = payload.artwork {
                    RemoteImage(url: artwork)
                } else {
                    LinearGradient(colors: [Color.accent2, Color.accent], startPoint: .topLeading, endPoint: .bottomTrailing)
                        .overlay(Image(systemName: "music.note").font(.title2).foregroundStyle(.white))
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(payload.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                Text([payload.artist, payload.album].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: payload.isPlaying ? "waveform" : "play.fill")
                .symbolEffect(.variableColor.iterative, isActive: payload.isPlaying)
                .foregroundStyle(Color.accent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: CardMetrics.compactPadding)
    }
}

struct ChartCard: View {
    let payload: ChartPayload
    private static let chartHeight: CGFloat = 160
    private var isLine: Bool { ["line", "area"].contains((payload.style ?? "bar").lowercased()) }

    var body: some View {
        VStack(alignment: .leading, spacing: CardMetrics.headerGap) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Kicker(text: payload.title ?? String(localized: "Trend"), symbol: payload.symbol ?? "chart.bar.fill")
                Spacer(minLength: 0)
                if let average = payload.average {
                    Text("Avg. \(ChartFormat.value(average))\(payload.unit.map { " \($0)" } ?? "")").font(.caption.weight(.medium)).foregroundStyle(Color.text2)
                }
            }
            Chart {
                ForEach(Array(payload.points.enumerated()), id: \.offset) { _, point in
                    if isLine {
                        LineMark(x: .value("x", point.label), y: .value("y", point.value))
                            .foregroundStyle(Color.accent)
                            .interpolationMethod(.catmullRom)
                            .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        AreaMark(x: .value("x", point.label), y: .value("y", point.value))
                            .foregroundStyle(LinearGradient(colors: [Color.accent.opacity(0.25), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.catmullRom)
                    } else {
                        BarMark(x: .value("x", point.label), y: .value("y", point.value), width: .ratio(0.55))
                            .foregroundStyle(LinearGradient(colors: [Color.accent2, Color.accent], startPoint: .top, endPoint: .bottom))
                            .cornerRadius(5)
                    }
                }
                if let average = payload.average {
                    RuleMark(y: .value("Average", average)).foregroundStyle(Color.text3).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                }
            }
            .chartXAxis { AxisMarks { _ in AxisValueLabel().font(.caption2).foregroundStyle(Color.text2) } }
            .chartYAxis {
                AxisMarks(position: .trailing) { _ in
                    AxisGridLine().foregroundStyle(Color.line)
                    AxisValueLabel().font(.caption2).foregroundStyle(Color.text3)
                }
            }
            .frame(height: Self.chartHeight)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}
