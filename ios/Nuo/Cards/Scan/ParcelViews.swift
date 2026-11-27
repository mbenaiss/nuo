import SwiftUI

extension ParcelPayload {
    init(_ p: Parcel) {
        self.init(
            id: p.id, number: p.number, label: p.label, carrier: p.carrierName, status: p.status, statusLabel: p.statusLabel,
            lastEvent: p.lastEvent?.label, lastEventAt: p.lastEvent?.at, eta: p.estimatedDelivery, url: p.url,
            events: p.events.map { ParcelEventPayload(label: $0.label, at: $0.at, location: $0.location) })
    }
}

enum ParcelFormat {
    static func eta(_ day: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: day) else { return day }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide).locale(.current))
    }

    static func moment(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute().locale(.current))
    }
}

/// `::parcel`: status, last event and expected delivery; tapping opens the history.
struct ParcelCard: View {
    let payload: ParcelPayload
    @State private var showsSheet = false

    var body: some View {
        Button {
            Haptics.tap()
            showsSheet = true
        } label: {
            ParcelSummary(payload: payload).contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .sheet(isPresented: $showsSheet) { ParcelSheetView(initial: payload) }
    }
}

struct ParcelSummary: View {
    let payload: ParcelPayload

    var body: some View {
        let tint = ParcelStatusStyle.color(payload.status)
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: ParcelStatusStyle.symbol(payload.status))
                    .font(.title3.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: 48, height: 48)
                    .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(payload.label ?? String(localized: "Parcel")).font(.headline).foregroundStyle(Color.ink).lineLimit(1)
                    Text([payload.carrier, payload.number].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.monospacedDigit()).foregroundStyle(Color.text2).lineLimit(1)
                }
                Spacer(minLength: Spacing.xs)
                Text(payload.statusLabel)
                    .font(.caption.weight(.bold)).foregroundStyle(tint)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(tint.opacity(0.14), in: Capsule())
            }
            if let last = payload.lastEvent {
                VStack(alignment: .leading, spacing: 2) {
                    Text(last).font(.subheadline).foregroundStyle(Color.ink).lineLimit(2)
                    if let at = payload.lastEventAt { Text(ParcelFormat.moment(at)).font(.caption).foregroundStyle(Color.text2) }
                }
            }
            if let eta = payload.eta, payload.status != "delivered" {
                Label("Expected delivery \(ParcelFormat.eta(eta))", systemImage: "calendar").font(.caption.weight(.semibold)).foregroundStyle(Color.text2)
            }
        }
    }
}

/// History of a parcel, with refresh and the carrier's page; from a scan, also « Suivre ce colis ».
struct ParcelSheetView: View {
    @State var initial: ParcelPayload
    /// Scan of a number not tracked yet: shows the label field and the track button.
    var detection: ParcelDetection?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scanAPI) private var api
    @Environment(\.openURL) private var openURL
    @State private var label = ""
    @State private var busy = false
    @State private var error: String?

    init(initial: ParcelPayload) {
        _initial = State(initialValue: initial)
        detection = nil
    }

    init(detection: ParcelDetection) {
        self.detection = detection.tracked == nil ? detection : nil
        _initial = State(initialValue: detection.tracked.map(ParcelPayload.init) ?? ParcelPayload(
            id: nil, number: detection.number, label: nil, carrier: detection.carrierName, status: "unknown",
            statusLabel: String(localized: "Not tracked yet"), lastEvent: nil, lastEventAt: nil, eta: nil, url: detection.url, events: []))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ParcelSummary(payload: initial).card()
                    if initial.id == nil { trackSection }
                    if !initial.events.isEmpty { history }
                    if let error { Text(error).font(.footnote).foregroundStyle(Color.bad) }
                    if let link = initial.url, let url = URL(string: link) {
                        Button { openURL(url) } label: { Label("Open the carrier tracking", systemImage: "safari") }
                            .font(.subheadline.weight(.semibold)).tint(Color.accentInk)
                    }
                }
                .padding(16)
            }
            .background(Color.canvas)
            .navigationTitle("Parcel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(Color.ink).accessibilityLabel("Close")
                }
                if initial.id != nil, api != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                            .disabled(busy).accessibilityLabel("Refresh")
                    }
                }
            }
        }
    }

    private var trackSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField("Label (e.g. Trail running shoes)", text: $label)
                .padding(12)
                .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous).strokeBorder(Color.line))
            Button { Task { await track() } } label: {
                Label(busy ? String(localized: "Adding…") : String(localized: "Track this parcel"), systemImage: "bell.badge").frame(maxWidth: .infinity)
            }
            .buttonStyle(InkButtonStyle())
            .disabled(busy || api == nil)
            Text("The gateway checks the parcel every 2 hours and notifies you of every status change.")
                .font(.caption).foregroundStyle(Color.text2)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionTitle(text: String(localized: "History"))
            ForEach(Array(initial.events.enumerated()), id: \.offset) { index, event in
                HStack(alignment: .top, spacing: Spacing.sm) {
                    Circle().fill(index == 0 ? ParcelStatusStyle.color(initial.status) : Color.line).frame(width: 9, height: 9).padding(.top, 5)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.label).font(.subheadline).foregroundStyle(Color.ink)
                        Text([event.at.map(ParcelFormat.moment), event.location].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(Color.text2)
                    }
                }
            }
        }
        .card()
    }

    private func track() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        do {
            let parcel = try await api.trackParcel(number: initial.number, label: label.trimmingCharacters(in: .whitespaces).isEmpty ? nil : label)
            withAnimation(.smooth) { initial = ParcelPayload(parcel) }
            error = nil
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
            Haptics.error()
        }
    }

    private func refresh() async {
        guard let api, let id = initial.id else { return }
        busy = true
        defer { busy = false }
        do {
            let parcel = try await api.refreshParcel(id: id)
            withAnimation(.smooth) { initial = ParcelPayload(parcel) }
            error = parcel.error
        } catch {
            self.error = error.localizedDescription
        }
    }
}
