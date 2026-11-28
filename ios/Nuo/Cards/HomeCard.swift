import SwiftUI

/// `::home`: alerts first, then the rooms, the devices and the day's energy.
struct HomeCard: View {
    let payload: HomePayload

    private static let tint = Color(hex: 0x3B82F6)

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            CardHeader(symbol: "house.fill", tint: Self.tint, title: payload.title ?? String(localized: "Home"),
                       subtitle: [payload.summary, payload.updated].compactMap { $0 }.joined(separator: " · ").nilIfEmpty)
            if !payload.alerts.isEmpty {
                VStack(spacing: Spacing.xs) {
                    ForEach(Array(payload.alerts.enumerated()), id: \.offset) { _, alert in HomeAlertRow(alert: alert) }
                }
            }
            if !payload.rooms.isEmpty {
                TileGrid(minimum: 140) {
                    ForEach(Array(payload.rooms.enumerated()), id: \.offset) { _, room in HomeRoomTile(room: room) }
                }
            }
            if !payload.devices.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Kicker(text: String(localized: "Devices"), symbol: "switch.2", tint: Color.text2)
                    TileGrid(minimum: 150) {
                        ForEach(Array(payload.devices.enumerated()), id: \.offset) { _, device in HomeDeviceTile(device: device) }
                    }
                }
            }
            if let energy = payload.energy { HomeEnergyView(energy: energy) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

private struct HomeAlertRow: View {
    let alert: HomeAlert

    var body: some View {
        let tint = style.tint
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(alert.text).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                if let detail = alert.detail {
                    Text(inlineMarkdown(detail)).font(.caption).foregroundStyle(Color.text2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous).strokeBorder(tint.opacity(0.22), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    private var style: CalloutStyle {
        switch alert.level {
        case "critical", "error", "danger", "alarm", "high": .error
        case "info", "notice", "low": .info
        case "ok", "success", "resolved": .success
        default: .warning
        }
    }

    private var symbol: String {
        if let symbol = alert.symbol { return symbol }
        let kind = alert.kind ?? ""
        let words: [(String, String)] = [
            ("window", "window.vertical.open"), ("door", "door.left.hand.open"), ("leak", "drop.fill"), ("water", "drop.fill"),
            ("smoke", "smoke.fill"), ("fire", "flame.fill"), ("co2", "aqi.high"), ("air", "aqi.high"), ("lock", "lock.open.fill"),
            ("battery", "battery.25percent"), ("power", "bolt.fill"), ("temperature", "thermometer.high"),
        ]
        return words.first { kind.contains($0.0) }?.1 ?? style.symbol
    }
}

private struct HomeRoomTile: View {
    let room: HomeRoom

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            HStack(spacing: Spacing.xxs) {
                Text(room.name).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                Spacer(minLength: 0)
                if room.heating == true {
                    Image(systemName: "flame.fill").font(.caption2).foregroundStyle(Color.accent)
                        .accessibilityLabel(String(localized: "Heating"))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xxs) {
                Text(room.temperature.map { $0.line() } ?? "-")
                    .font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .lineLimit(1).minimumScaleFactor(0.7)
                if let target = room.target {
                    Text(verbatim: "→ \(target.line())").font(.caption.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                        .accessibilityLabel(String(localized: "Target \(target.line())"))
                }
            }
            if room.humidity != nil || room.co2 != nil {
                HStack(spacing: Spacing.sm) {
                    if let humidity = room.humidity {
                        Label(humidity.line(maxFraction: 0), systemImage: "humidity.fill")
                            .accessibilityLabel(String(localized: "Humidity \(humidity.line(maxFraction: 0))"))
                    }
                    if let co2 = room.co2 {
                        Label(co2.line(maxFraction: 0), systemImage: "aqi.medium")
                            .foregroundStyle(co2Tint(co2.number))
                            .accessibilityLabel(Text(verbatim: "CO₂ \(co2.line(maxFraction: 0))"))
                    }
                }
                .font(.caption2.monospacedDigit())
                .labelStyle(CompactLabelStyle())
                .foregroundStyle(Color.text2)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Indoor CO₂: past 1,000 ppm the air wants renewing, past 1,500 it is poor.
    private func co2Tint(_ ppm: Double?) -> Color {
        guard let ppm else { return Color.text2 }
        if ppm >= 1500 { return .bad }
        if ppm >= 1000 { return CalloutStyle.warning.tint }
        return Color.text2
    }
}

private struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}

private struct HomeDeviceTile: View {
    let device: HomeDevice

    var body: some View {
        let on = device.isOn == true
        HStack(spacing: Spacing.xs) {
            Image(systemName: symbol)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(on ? tint : Color.text3)
                .frame(width: 30, height: 30)
                .background(on ? tint.opacity(0.16) : Color.chip, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.subheadline.weight(.medium)).foregroundStyle(Color.ink).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(on ? Color.ink : Color.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.xs)
        .padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let state = device.state ?? device.isOn.map {
            $0 ? String(localized: "card.home.on", defaultValue: "On") : String(localized: "card.home.off", defaultValue: "Off")
        }
        return [state, device.room].compactMap { $0 }.joined(separator: " · ")
    }

    private var kind: String { (device.kind ?? device.name).lowercased() }

    private var symbol: String {
        if let symbol = device.symbol { return symbol }
        let table: [(words: [String], symbol: String)] = [
            (["light", "lamp", "lumi", "lampe"], "lightbulb.fill"),
            (["heat", "radiator", "thermostat", "climate", "chauff", "radiateur"], "heater.vertical.fill"),
            (["blind", "shutter", "cover", "volet", "store"], "blinds.horizontal.closed"),
            (["plug", "outlet", "switch", "prise"], "powerplug.fill"),
            (["lock", "door", "serrure", "porte"], "lock.fill"),
            (["fan", "ventil"], "fan.fill"),
            (["vacuum", "aspirateur"], "fan.ceiling.fill"),
            (["tv", "télé", "media", "speaker", "enceinte"], "tv.fill"),
            (["washer", "washing", "lave", "dryer"], "washer.fill"),
            (["camera", "caméra"], "video.fill"),
            (["alarm", "alarme"], "bell.fill"),
            (["car", "charger", "voiture", "borne"], "ev.charger.fill"),
        ]
        return table.first { $0.words.contains(where: kind.contains) }?.symbol ?? "poweroutlet.type.f.fill"
    }

    private var tint: Color {
        let symbol = self.symbol
        if symbol.hasPrefix("lightbulb") { return Color(hex: 0xF5A623) }
        if symbol.hasPrefix("heater") { return .accent }
        return Color(hex: 0x3B82F6)
    }
}

private struct HomeEnergyView: View {
    let energy: HomeEnergy

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Kicker(text: String(localized: "Energy"), symbol: "bolt.fill", tint: Color.text2)
            TileGrid(minimum: 92) {
                if let today = energy.today { StatTile(label: String(localized: "Today"), quantity: today) }
                if let now = energy.now { StatTile(label: String(localized: "Right now"), quantity: now) }
                if let cost = energy.cost { StatTile(label: String(localized: "Cost"), value: cost) }
            }
            if let note = energy.note {
                Text(note).font(.caption).foregroundStyle(Color.text2)
            }
        }
    }
}
