import MapKit
import SwiftUI

struct PlaceSelection: Equatable {
    var place: ReminderPlace
    var trigger: String
}

/// Address suggestions while typing (MKLocalSearchCompleter), biased towards Paris, never towards the user's position.
@MainActor
@Observable
final class AddressCompleter: NSObject, MKLocalSearchCompleterDelegate {
    struct Suggestion: Hashable, Sendable, Identifiable {
        let title: String
        let subtitle: String
        var id: String { title + "|" + subtitle }
    }

    private(set) var suggestions: [Suggestion] = []
    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        completer.region = PlaceMap.paris
    }

    func update(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            suggestions = []
            completer.cancel()
        } else {
            completer.queryFragment = trimmed
        }
    }

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results.prefix(8).map { Suggestion(title: $0.title, subtitle: $0.subtitle) }
        Task { @MainActor in self.suggestions = Array(results) }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: any Error) {
        Task { @MainActor in self.suggestions = [] }
    }

    /// Coordinates of a suggestion.
    func resolve(_ suggestion: Suggestion) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = suggestion.subtitle.isEmpty ? suggestion.title : "\(suggestion.title), \(suggestion.subtitle)"
        request.region = completer.region
        guard let response = try? await MKLocalSearch(request: request).start(), let item = response.mapItems.first else { return nil }
        return item.location.coordinate
    }
}

struct PlacePickerSheet: View {
    let initial: PlaceSelection?
    let onDone: (PlaceSelection?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var places = PlacesStore.shared
    @State private var completer = AddressCompleter()
    @State private var search = ""
    @State private var selected: Place?
    @State private var trigger = "arrive"
    @State private var radius: Double = 150
    @State private var name = ""
    @State private var camera: MapCameraPosition = .region(PlaceMap.paris)
    @State private var resolving = false
    @State private var saving = false
    private let access = LocationAccess.shared

    private var isNew: Bool { selected?.id.isEmpty == true }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    map
                        .listRowInsets(EdgeInsets())
                    Picker("Trigger", selection: $trigger) {
                        Text("On arrival").tag("arrive")
                        Text("On leaving").tag("leave")
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Radius").foregroundStyle(Color.ink)
                            Spacer()
                            Text(verbatim: "\(Int(radius)) m").font(.subheadline.monospacedDigit()).foregroundStyle(Color.text2)
                        }
                        Slider(value: $radius, in: 100...500, step: 25)
                            .disabled(selected == nil)
                    }
                    if isNew {
                        TextField("Place name (Home, Office…)", text: $name)
                    }
                } footer: {
                    Text(selected.map { footer($0) } ?? String(localized: "Pick a saved place or search for an address."))
                }
                .listRowBackground(Color.card)

                if access.isDenied {
                    Section { LocationDeniedBanner() }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                }

                if !search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Section {
                        if completer.suggestions.isEmpty {
                            Text("No suggestions").foregroundStyle(Color.text2)
                        }
                        ForEach(completer.suggestions) { suggestion in
                            Button { Task { await pick(suggestion) } } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "mappin.circle.fill").font(.title3).foregroundStyle(Color.bad)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(suggestion.title).foregroundStyle(Color.ink)
                                        if !suggestion.subtitle.isEmpty {
                                            Text(suggestion.subtitle).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                                        }
                                    }
                                    Spacer()
                                    if resolving { ProgressView().controlSize(.small) }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        SectionHeader(title: String(localized: "Addresses"))
                    }
                    .listRowBackground(Color.card)
                }

                Section {
                    if places.places.isEmpty {
                        Text("No places. Search for an address to add one.").foregroundStyle(Color.text2)
                    }
                    ForEach(places.places) { place in
                        Button { select(place) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: PlaceStyle.symbol(place.name))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color(hex: 0x0E7C66))
                                    .frame(width: 32, height: 32)
                                    .background(Color(hex: 0x14B8A6).opacity(0.13), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(place.name).foregroundStyle(Color.ink)
                                    if let address = place.address {
                                        Text(address).font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                                    }
                                }
                                Spacer()
                                if selected?.id == place.id {
                                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accent)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    SectionHeader(title: String(localized: "Saved places"))
                }
                .listRowBackground(Color.card)

                if initial != nil {
                    Section {
                        Button("Remove place", role: .destructive) {
                            onDone(nil)
                            dismiss()
                        }
                    }
                    .listRowBackground(Color.card)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Place")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for an address")
            .onChange(of: search) { _, value in completer.update(value) }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("OK") { Task { await save() } }
                            .disabled(selected == nil || (isNew && name.trimmingCharacters(in: .whitespaces).isEmpty))
                    }
                }
            }
        }
        .onAppear(perform: fill)
        .task { if !places.loaded { await places.load() } }
    }

    private var map: some View {
        MapReader { proxy in
            Map(position: $camera, interactionModes: [.pan, .zoom]) {
                if let selected {
                    let center = CLLocationCoordinate2D(latitude: selected.lat, longitude: selected.lon)
                    MapCircle(center: center, radius: radius)
                        .foregroundStyle(Color(hex: 0x14B8A6).opacity(0.18))
                        .stroke(Color(hex: 0x0E7C66), lineWidth: 2)
                    Marker(selected.name.isEmpty ? String(localized: "New place") : selected.name, systemImage: PlaceStyle.symbol(selected.name), coordinate: center)
                        .tint(Color(hex: 0x0E7C66))
                }
            }
            .mapStyle(.standard(pointsOfInterest: .excludingAll))
            .gesture(
                LongPressGesture(minimumDuration: 0.4)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        guard case let .second(true, drag?) = value, let coordinate = proxy.convert(drag.location, from: .local) else { return }
                        dropPin(at: coordinate)
                    }
            )
        }
        .frame(height: 230)
        .overlay(alignment: .bottom) {
            if selected == nil {
                Text("Search for an address or long-press the map")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 10)
                    .allowsHitTesting(false)
            }
        }
        .animation(.snappy, value: radius)
    }

    private func dropPin(at coordinate: CLLocationCoordinate2D) {
        Haptics.send()
        let place = Place(id: "", name: "", address: nil, lat: coordinate.latitude, lon: coordinate.longitude, radiusM: radius)
        selected = place
        name = ""
    }

    private func footer(_ place: Place) -> String {
        let name = place.name.isEmpty ? String(localized: "this place") : place.name
        if trigger == "leave" {
            return String(localized: "The reminder rings when you leave a \(Int(radius)) m radius around \(name). Nuo doesn't track your location: iOS detects this perimeter.")
        }
        return String(localized: "The reminder rings when you arrive within a \(Int(radius)) m radius of \(name). Nuo doesn't track your location: iOS detects this perimeter.")
    }

    private func fill() {
        guard let initial else { return }
        trigger = initial.trigger
        let place = places.place(id: initial.place.id) ?? Place(id: initial.place.id, name: initial.place.name, lat: initial.place.lat,
                                                               lon: initial.place.lon, radiusM: initial.place.radiusM)
        select(place, trigger: initial.trigger)
    }

    private func select(_ place: Place, trigger: String? = nil) {
        Haptics.selection()
        selected = place
        radius = min(max(place.radiusM, 100), 500)
        name = place.name
        if let trigger { self.trigger = trigger }
        focus(on: place)
    }

    private func focus(on place: Place) {
        withAnimation(.smooth) {
            let span = max(place.radiusM, 100) * 5
            camera = .region(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon),
                                                latitudinalMeters: span, longitudinalMeters: span))
        }
    }

    private func pick(_ suggestion: AddressCompleter.Suggestion) async {
        resolving = true
        defer { resolving = false }
        guard let coordinate = await completer.resolve(suggestion) else {
            Haptics.error()
            return
        }
        let place = Place(id: "", name: "", address: [suggestion.title, suggestion.subtitle].filter { !$0.isEmpty }.joined(separator: ", "),
                          lat: coordinate.latitude, lon: coordinate.longitude, radiusM: 150)
        select(place)
        name = ""
        search = ""
    }

    private func save() async {
        guard var place = selected else { return }
        saving = true
        defer { saving = false }
        if isNew {
            guard let created = await places.create(PlaceDraft(name: name.trimmingCharacters(in: .whitespaces), address: place.address,
                                                               lat: place.lat, lon: place.lon, radiusM: radius)) else { return }
            place = created
        } else if abs(place.radiusM - radius) >= 1 {
            if let updated = await places.update(place.id, patch: ["radiusM": .number(radius)]) { place = updated }
        }
        await access.requestIfNeeded()
        Haptics.success()
        onDone(PlaceSelection(place: place.asReminderPlace, trigger: trigger))
        dismiss()
    }
}

enum PlaceMap {
    /// Where the map starts when no place is selected: never the user's position.
    static let paris = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 48.8566, longitude: 2.3522),
                                          latitudinalMeters: 12_000, longitudinalMeters: 12_000)
}

enum PlaceStyle {
    static func symbol(_ name: String) -> String {
        let folded = ReminderParser.fold(name)
        if folded.contains("maison") || folded.contains("home") || folded.contains("appart") { return "house.fill" }
        if folded.contains("bureau") || folded.contains("travail") || folded.contains("office") { return "briefcase.fill" }
        if folded.contains("sport") || folded.contains("gym") { return "dumbbell.fill" }
        if folded.contains("gare") { return "tram.fill" }
        if folded.contains("ecole") { return "graduationcap.fill" }
        return "mappin"
    }
}

/// « Lieux »: rename or delete saved places.
struct PlacesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = PlacesStore.shared
    @State private var renaming: Place?
    @State private var newName = ""
    @State private var pendingDelete: Place?
    @State private var adding = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if store.places.isEmpty {
                        WorkspaceEmptyState(symbol: "mappin.slash", title: String(localized: "No places"), message: String(localized: "Add “Home” or “Office” for reminders that ring when you arrive or leave."))
                            .listRowBackground(Color.clear)
                    }
                    ForEach(store.places) { place in
                        HStack(spacing: 12) {
                            Image(systemName: PlaceStyle.symbol(place.name))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Color(hex: 0x0E7C66))
                                .frame(width: 34, height: 34)
                                .background(Color(hex: 0x14B8A6).opacity(0.13), in: Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(place.name).foregroundStyle(Color.ink)
                                Text([place.address, String(localized: "radius \(Int(place.radiusM)) m")].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(Color.text2).lineLimit(1)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = place } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                newName = place.name
                                renaming = place
                            } label: { Label("Rename", systemImage: "pencil") }
                            .tint(Color.text2)
                        }
                        .contextMenu {
                            Button {
                                newName = place.name
                                renaming = place
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button(role: .destructive) { pendingDelete = place } label: { Label("Delete", systemImage: "trash") }
                        }
                    }
                } footer: {
                    Text("Agents can also use these places by name.")
                }
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("OK") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add a place")
                }
            }
            .alert("Rename Place", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Rename") {
                    guard let place = renaming else { return }
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty, name != place.name else { return }
                    Task { await store.update(place.id, patch: ["name": .string(name)]) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete “\(pendingDelete?.name ?? "")”?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    guard let place = pendingDelete else { return }
                    Task { await store.delete(place) }
                }
            } message: {
                Text("Reminders that use it keep working until they are next edited.")
            }
            .sheet(isPresented: $adding) {
                PlacePickerSheet(initial: nil) { _ in }
            }
            .task { await store.load() }
        }
    }
}
