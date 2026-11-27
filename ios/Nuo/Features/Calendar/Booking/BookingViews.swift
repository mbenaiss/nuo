import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

enum BookingSheet: Identifiable {
    case editor(BookingType?)
    case share(BookingType)
    case proposal

    var id: String {
        switch self {
        case let .editor(type): "editor-\(type?.id ?? "new")"
        case let .share(type): "share-\(type.id)"
        case .proposal: "proposal"
        }
    }
}

/// Bookings: booking pages (Openings), one-off Proposals and the bookings to come.
struct BookingHomeView: View {
    @State private var store = BookingStore.shared
    @State private var sheet: BookingSheet?
    @State private var cancelling: Booking?
    @State private var cancelReason = ""

    var body: some View {
        GroupedList {
            if let error = store.error {
                Section { StaleBanner(message: error) { Task { await store.load() } } }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }
            Section {
                ForEach(store.openings) { type in
                    BookingTypeRow(type: type, upcoming: store.bookings(of: type.id).count) { sheet = .share(type) }
                        .contentShape(Rectangle())
                        .onTapGesture { sheet = .editor(type) }
                        .contextMenu { typeMenu(type) }
                }
                if store.openings.isEmpty, store.loaded {
                    Text("Create a public page: people pick a free slot and the invitation comes from your Google Calendar.")
                        .font(.footnote).foregroundStyle(Color.text2)
                }
                Button { sheet = .editor(nil) } label: { Label("New booking page", systemImage: "plus.circle.fill") }
            } header: {
                Text("Booking pages")
            }
            Section {
                ForEach(store.proposals) { type in
                    BookingTypeRow(type: type, upcoming: store.bookings(of: type.id).count) { sheet = .share(type) }
                        .contentShape(Rectangle())
                        .onTapGesture { sheet = .editor(type) }
                        .contextMenu { typeMenu(type) }
                }
                Button { sheet = .proposal } label: { Label("Propose times", systemImage: "calendar.badge.plus") }
            } header: {
                Text("Proposals")
            } footer: {
                Text("A proposal offers a few chosen slots and closes after the first booking.")
            }
            Section("Upcoming") {
                if store.bookings.isEmpty {
                    Text(store.loaded ? String(localized: "No bookings yet.") : String(localized: "Loading…")).font(.footnote).foregroundStyle(Color.text2)
                }
                ForEach(store.bookings) { booking in
                    BookingRow(booking: booking)
                        .contextMenu {
                            if let meet = booking.meetUrl.flatMap(URL.init(string:)) { Link(destination: meet) { Label("Join", systemImage: "video") } }
                            Button(role: .destructive) { cancelling = booking } label: { Label("Cancel booking", systemImage: "xmark.circle") }
                        }
                        #if os(iOS)
                        .swipeActions {
                            Button(role: .destructive) { cancelling = booking } label: { Label("Cancel", systemImage: "xmark.circle") }
                        }
                        #endif
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Bookings")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { sheet = .editor(nil) } label: { Label("New booking page", systemImage: "link.badge.plus") }
                    Button { sheet = .proposal } label: { Label("Propose times", systemImage: "calendar.badge.plus") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("New")
            }
        }
        .refreshable { await store.load() }
        .task {
            await store.load()
            if let demo = BookingDemo.sheet(store: store) { sheet = demo }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case let .editor(type): BookingTypeEditor(original: type)
            case let .share(type): BookingShareView(type: type)
            case .proposal: ProposalFlowView()
            }
        }
        .alert("Cancel this booking?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } })) {
            TextField("Reason (optional)", text: $cancelReason)
            Button("Cancel booking", role: .destructive) {
                guard let booking = cancelling else { return }
                let reason = cancelReason.trimmingCharacters(in: .whitespaces)
                Task { _ = await store.cancel(booking, reason: reason.isEmpty ? nil : reason) }
                cancelReason = ""
            }
            Button("Keep", role: .cancel) { cancelReason = "" }
        } message: {
            if let booking = cancelling {
                Text("\(booking.invitee.name) · \(AgendaText.shortDay(booking.start)) at \(AgendaText.time(booking.start)). The Google event is deleted.")
            }
        }
    }

    @ViewBuilder
    private func typeMenu(_ type: BookingType) -> some View {
        if let url = type.shareURL {
            Button { PlatformPasteboard.copy(url.absoluteString); Haptics.success() } label: { Label("Copy link", systemImage: "doc.on.doc") }
            ShareLink(item: url) { Label("Share…", systemImage: "square.and.arrow.up") }
            Button { sheet = .share(type) } label: { Label("QR code", systemImage: "qrcode") }
        }
        Button { sheet = .editor(type) } label: { Label("Edit", systemImage: "pencil") }
        Button { Task { await store.setActive(type, !type.active) } } label: {
            Label(type.active ? String(localized: "Disable") : String(localized: "Enable"), systemImage: type.active ? "pause.circle" : "play.circle")
        }
        Divider()
        Button(role: .destructive) { Task { await store.archive(type) } } label: { Label("Archive", systemImage: "archivebox") }
    }
}

struct BookingTypeRow: View {
    let type: BookingType
    let upcoming: Int
    let onShare: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: type.kind == .proposal ? "calendar.badge.clock" : "link")
                .font(.body.weight(.semibold))
                .foregroundStyle(type.active ? Color.accent : Color.text3)
                .frame(width: Spacing.xxl + Spacing.xxs, height: Spacing.xxl + Spacing.xxs)
                .background(type.active ? Color.accentSoft : Color.chip, in: RoundedRectangle(cornerRadius: Radius.xs, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    Text(type.title).font(.body.weight(.semibold)).foregroundStyle(type.active ? Color.ink : Color.text3).lineLimit(1)
                    if !type.active { Badge(text: type.kind == .proposal ? String(localized: "Closed") : String(localized: "Inactive")) }
                }
                let location = BookingText.location(type.location)
                HStack(spacing: Spacing.sm) {
                    Label(AgendaText.duration(Double(type.durationMin) * 60), systemImage: "clock")
                    Label(location.label, systemImage: location.symbol).lineLimit(1)
                }
                .font(.caption).foregroundStyle(Color.text2).labelStyle(TightLabelStyle())
                Text(subtitle).font(.caption).foregroundStyle(Color.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            Button(action: onShare) {
                Image(systemName: "square.and.arrow.up")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.text2)
                    .frame(width: Spacing.xxl + Spacing.xs, height: Spacing.xxl + Spacing.xs)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share link")
        }
        .padding(.vertical, Spacing.xxs)
    }

    private var subtitle: String {
        var parts: [String] = []
        if type.kind == .proposal {
            parts.append(String(localized: "\(type.candidateSlots?.count ?? 0) proposed slots"))
        } else {
            parts.append(BookingText.hours(type.workingHours))
        }
        if upcoming > 0 { parts.append(String(localized: "\(upcoming) upcoming")) }
        return parts.joined(separator: " · ")
    }
}

struct BookingRow: View {
    let booking: Booking

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            VStack(spacing: 0) {
                Text(booking.start.formatted(Date.FormatStyle(locale: .current).weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(.bold)).foregroundStyle(Color.accent)
                Text(verbatim: "\(AgendaCalendar.current.component(.day, from: booking.start))")
                    .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Color.ink)
            }
            .frame(width: Spacing.xxl + Spacing.xs)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Spacing.xs) {
                    Text(booking.invitee.name).font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                    let status = BookingText.status(booking.status)
                    if booking.status != "confirmed" { Badge(text: status.label, dot: status.color) }
                }
                Text(verbatim: "\(booking.typeTitle ?? String(localized: "Appointment")) · \(AgendaText.time(booking.start)) – \(AgendaText.time(booking.end))")
                    .font(.caption).foregroundStyle(Color.text2)
                Text(booking.invitee.email).font(.caption).foregroundStyle(Color.text3).lineLimit(1)
            }
            Spacer(minLength: 0)
            if let meet = booking.meetUrl.flatMap(URL.init(string:)), booking.end > Date() {
                JoinButton(url: meet, prominent: booking.start.timeIntervalSinceNow < 15 * 60)
            }
        }
        .padding(.vertical, Spacing.xxs)
    }
}

/// The public link of a booking type: QR code, copy, share sheet.
struct BookingShareView: View {
    let type: BookingType
    /// Inside another navigation stack (end of the proposal flow).
    var embedded = false
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #else
                .frame(minWidth: 420, minHeight: 520)
                #endif
        }
    }

    private var content: some View {
        VStack(spacing: Spacing.lg) {
            Spacer(minLength: Spacing.md)
            if let url = type.shareURL {
                QRCodeView(text: url.absoluteString)
                    .frame(width: CalendarMetrics.qrSize, height: CalendarMetrics.qrSize)
                    .padding(Spacing.md)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous).strokeBorder(Color.line))
                VStack(spacing: Spacing.xxs) {
                    Text(type.title).font(.title3.bold()).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                    Text(url.absoluteString.replacingOccurrences(of: "https://", with: ""))
                        .font(.callout.monospaced()).foregroundStyle(Color.text2).textSelection(.enabled)
                    if let slots = type.candidateSlots, type.kind == .proposal, !slots.isEmpty {
                        Text("\(slots.count) proposed slots")
                            .font(.footnote).foregroundStyle(Color.text3)
                    }
                }
                HStack(spacing: Spacing.sm) {
                    Button {
                        PlatformPasteboard.copy(url.absoluteString)
                        Haptics.success()
                        withAnimation(.snappy) { copied = true }
                    } label: {
                        Label(copied ? String(localized: "Copied") : String(localized: "Copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(InkButtonStyle(prominent: false))
                    ShareLink(item: url, subject: Text(type.title), message: Text("Pick a time: ")) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(InkButtonStyle())
                }
                .padding(.horizontal, Spacing.gutter)
            } else {
                WorkspaceEmptyState(symbol: "link.badge.plus", title: String(localized: "No public link"),
                                    message: String(localized: "The gateway has no booking address (NUO_BOOKING_HOSTS)."))
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Color.canvas)
        .navigationTitle("Share")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("OK") { dismiss() } } }
    }
}

struct QRCodeView: View {
    let text: String

    var body: some View {
        if let image = Self.image(text) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("Link QR code")
        } else {
            Image(systemName: "qrcode").resizable().scaledToFit().foregroundStyle(Color.text3)
        }
    }

    private static func image(_ text: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}

enum BookingDemo {
    @MainActor private static var taken = false

    /// `-demoBooking editor|new|share|proposal` opens a sheet of the Bookings screen once at launch.
    @MainActor static func sheet(store: BookingStore) -> BookingSheet? {
        let arguments = ProcessInfo.processInfo.arguments
        guard !taken, arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoBooking"), index + 1 < arguments.count else { return nil }
        taken = true
        switch arguments[index + 1] {
        case "editor": return .editor(store.openings.first)
        case "new": return .editor(nil)
        case "share": return store.openings.first.map { .share($0) }
        case "proposal": return .proposal
        default: return nil
        }
    }
}
