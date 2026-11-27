import CoreLocation
import Foundation
import MapKit
import WeatherKit

/// One-shot position for the bots. With « Toujours » the iPhone can answer from the background (silent push).
@MainActor
final class DeviceLocator: NSObject, CLLocationManagerDelegate {
    static let shared = DeviceLocator()

    private let manager = CLLocationManager()
    private var waiters: [CheckedContinuation<CLLocation, any Error>] = []
    private var attempt = 0
    private(set) var status: CLAuthorizationStatus
    /// Fires on every authorization change, so the settings screen and the capabilities follow.
    var onChange: (() -> Void)?

    override private init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    #if os(iOS)
    var isAuthorized: Bool { status == .authorizedAlways || status == .authorizedWhenInUse }
    #else
    var isAuthorized: Bool { status == .authorizedAlways }
    #endif
    var isAlways: Bool { status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// iOS only offers « Toujours » once « Lorsque l'app est active » is granted.
    func requestAccess() {
        #if os(iOS)
        switch status {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
        default: break
        }
        #else
        if status == .notDetermined { manager.requestAlwaysAuthorization() }
        #endif
    }

    func current() async throws -> CLLocation {
        if let last = manager.location, -last.timestamp.timeIntervalSinceNow < 120, last.horizontalAccuracy <= 200 { return last }
        guard isAuthorized else {
            throw DeviceToolError("Nuo n'a pas accès à la position sur \(PlatformDevice.name) : demande à l'utilisateur de l'autoriser dans Nuo, Réglages › Accès des bots.")
        }
        let fallback = manager.location
        do {
            return try await withCheckedThrowingContinuation { c in
                waiters.append(c)
                guard waiters.count == 1 else { return }
                attempt += 1
                let current = attempt
                manager.requestLocation()
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(15))
                    guard let self, self.attempt == current else { return }
                    self.finish(.failure(DeviceToolError("Position introuvable : pas de signal GPS ni Wi-Fi assez précis en 15 secondes.")))
                }
            }
        } catch {
            // A background request without « Toujours » fails: the last known position still beats nothing.
            if let fallback { return fallback }
            throw error as? DeviceToolError ?? DeviceToolError("Position indisponible : \(error.localizedDescription)")
        }
    }

    private func finish(_ result: Result<CLLocation, any Error>) {
        attempt += 1
        let pending = waiters
        waiters = []
        for c in pending { c.resume(with: result) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        MainActor.assumeIsolated { finish(.success(last)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated { finish(.failure(error)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.status = status
            onChange?()
        }
    }
}

/// `device_location`, `weather`, `maps_search` and `maps_route`.
@MainActor
final class PlaceTools {
    private let locator = DeviceLocator.shared

    func run(_ tool: String, _ args: DeviceToolArgs) async throws -> JSONValue {
        switch tool {
        case "device_location": return try await location()
        case "weather": return try await weather(args)
        case "maps_search": return try await search(args)
        case "maps_route": return try await route(args)
        default: throw DeviceToolError("Outil inconnu \(tool).")
        }
    }

    // MARK: Places

    private struct Place {
        let item: MKMapItem
        let label: String
        var location: CLLocation { item.location }
    }

    private func here() async throws -> Place {
        let location = try await locator.current()
        let item = (try? await MKReverseGeocodingRequest(location: location)?.mapItems.first) ?? MKMapItem(location: location, address: nil)
        return Place(item: item, label: Self.address(item) ?? "Position actuelle")
    }

    private func place(_ args: DeviceToolArgs, _ key: String) async throws -> Place {
        if args.isHere(key) { return try await here() }
        let text = args.string(key)!
        guard let request = MKGeocodingRequest(addressString: text), let item = try? await request.mapItems.first else {
            // A place name ("Musée d'Orsay") is not an address: ask a search instead.
            let search = MKLocalSearch.Request()
            search.naturalLanguageQuery = text
            if let item = try? await MKLocalSearch(request: search).start().mapItems.first { return Place(item: item, label: item.name ?? text) }
            throw DeviceToolError("Lieu introuvable : « \(text) ».")
        }
        return Place(item: item, label: item.name ?? Self.address(item) ?? text)
    }

    private static func address(_ item: MKMapItem) -> String? {
        item.address?.fullAddress.replacingOccurrences(of: "\n", with: ", ") ?? item.address?.shortAddress
    }

    private static func coordinates(_ l: CLLocation) -> JSONValue {
        .object(["latitude": .rounded(l.coordinate.latitude, 5), "longitude": .rounded(l.coordinate.longitude, 5)])
    }

    private func location() async throws -> JSONValue {
        let place = try await here()
        let l = place.location
        return .fields([
            "latitude": .rounded(l.coordinate.latitude, 5),
            "longitude": .rounded(l.coordinate.longitude, 5),
            "accuracyMeters": .number(l.horizontalAccuracy.rounded()),
            "address": .string(place.label),
            "city": .str(place.item.addressRepresentations?.cityName),
            "at": .string(DeviceToolDate.format(l.timestamp)),
            "ageMinutes": -l.timestamp.timeIntervalSinceNow > 300 ? .number((-l.timestamp.timeIntervalSinceNow / 60).rounded()) : nil,
            "device": .string(PlatformDevice.name),
        ])
    }

    // MARK: Weather

    private func weather(_ args: DeviceToolArgs) async throws -> JSONValue {
        let place = try await place(args, "place")
        let days = args.int("days", default: 3, range: 1...10)
        let hours = args.int("hours", default: 12, range: 0...48)
        let w: Weather
        do {
            w = try await WeatherService.shared.weather(for: place.location)
        } catch {
            throw DeviceToolError("Météo Apple indisponible : \(error.localizedDescription)")
        }
        let c = w.currentWeather
        let celsius = { (t: Measurement<UnitTemperature>) in JSONValue.rounded(t.converted(to: .celsius).value, 1) }
        let kmh = { (s: Measurement<UnitSpeed>) in JSONValue.number(s.converted(to: .kilometersPerHour).value.rounded()) }
        let percent = { (v: Double) in JSONValue.number((v * 100).rounded()) }
        let now = Date()
        let hourly = w.hourlyForecast.forecast.filter { $0.date >= now.addingTimeInterval(-1800) }.prefix(hours).map { h in
            JSONValue.object(["at": .string(DeviceToolDate.format(h.date)), "temperatureC": celsius(h.temperature), "condition": .string(h.condition.description), "precipitationChance": percent(h.precipitationChance)])
        }
        let daily = w.dailyForecast.forecast.prefix(days).map { d in
            JSONValue.fields([
                "date": .string(DeviceToolDate.format(d.date, dayOnly: true)),
                "highC": celsius(d.highTemperature),
                "lowC": celsius(d.lowTemperature),
                "condition": .string(d.condition.description),
                "precipitationChance": percent(d.precipitationChance),
                "sunrise": .str(d.sun.sunrise.map { DeviceToolDate.format($0) }),
                "sunset": .str(d.sun.sunset.map { DeviceToolDate.format($0) }),
            ])
        }
        return .fields([
            "place": .string(place.label),
            "current": .object([
                "temperatureC": celsius(c.temperature),
                "feelsLikeC": celsius(c.apparentTemperature),
                "condition": .string(c.condition.description),
                "humidity": percent(c.humidity),
                "windKmh": kmh(c.wind.speed),
                "uvIndex": .number(Double(c.uvIndex.value)),
            ]),
            "hourly": hours > 0 ? .array(hourly) : nil,
            "daily": .array(daily),
            "attribution": .string("Données Apple Météo (https://weatherkit.apple.com/legal-attribution.html)"),
        ])
    }

    // MARK: Maps

    private func search(_ args: DeviceToolArgs) async throws -> JSONValue {
        guard let query = args.string("query") else { throw DeviceToolError("query requis.") }
        let center = try await place(args, "near")
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = MKCoordinateRegion(center: center.location.coordinate, latitudinalMeters: 8000, longitudinalMeters: 8000)
        request.resultTypes = [.pointOfInterest, .address]
        let items: [MKMapItem]
        do {
            items = try await MKLocalSearch(request: request).start().mapItems
        } catch {
            return .object(["near": .string(center.label), "results": .array([])])
        }
        let max = args.int("max", default: 8, range: 1...25)
        let results = items
            .sorted { $0.location.distance(from: center.location) < $1.location.distance(from: center.location) }
            .prefix(max)
            .map { item in
                JSONValue.fields([
                    "name": .str(item.name),
                    "address": .str(Self.address(item)),
                    "distanceMeters": .number(item.location.distance(from: center.location).rounded()),
                    "category": .str(item.pointOfInterestCategory.map { $0.rawValue.replacingOccurrences(of: "MKPOICategory", with: "") }),
                    "phone": .str(item.phoneNumber),
                    "website": .str(item.url?.absoluteString),
                    "coordinates": Self.coordinates(item.location),
                    "mapsLink": .string(Self.mapsLink(query: item.name ?? query, at: item.location)),
                ])
            }
        return .object(["near": .string(center.label), "results": .array(Array(results))])
    }

    private static func mapsLink(query: String, at l: CLLocation) -> String {
        var c = URLComponents(string: "https://maps.apple.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "ll", value: "\(l.coordinate.latitude),\(l.coordinate.longitude)")]
        return c.url!.absoluteString
    }

    private func route(_ args: DeviceToolArgs) async throws -> JSONValue {
        guard args.string("to") != nil else { throw DeviceToolError("to requis.") }
        let from = try await place(args, "from")
        let to = try await place(args, "to")
        let mode = args.string("mode") ?? "driving"
        let request = MKDirections.Request()
        request.source = from.item
        request.destination = to.item
        request.transportType = switch mode {
        case "walking": .walking
        case "transit": .transit
        default: .automobile
        }
        if let arrival = try DeviceToolDate.require(args, "arrival") { request.arrivalDate = arrival.date }
        else if let departure = try DeviceToolDate.require(args, "departure") { request.departureDate = departure.date }
        let flag = mode == "walking" ? "w" : mode == "transit" ? "r" : "d"
        var link = URLComponents(string: "https://maps.apple.com/")!
        link.queryItems = [
            URLQueryItem(name: "saddr", value: "\(from.location.coordinate.latitude),\(from.location.coordinate.longitude)"),
            URLQueryItem(name: "daddr", value: "\(to.location.coordinate.latitude),\(to.location.coordinate.longitude)"),
            URLQueryItem(name: "dirflg", value: flag),
        ]
        let base: [(String, JSONValue?)] = [("from", .string(from.label)), ("to", .string(to.label)), ("mode", .string(mode)), ("mapsLink", .string(link.url!.absoluteString))]
        // Apple gives transit times only as an ETA, without the steps.
        if mode == "transit" {
            let eta: MKDirections.ETAResponse
            do { eta = try await MKDirections(request: request).calculateETA() } catch { throw DeviceToolError("Pas d'itinéraire en transports en commun trouvé : \(error.localizedDescription)") }
            return Self.merge(base, [
                ("durationMinutes", .number((eta.expectedTravelTime / 60).rounded())),
                ("distanceKm", .rounded(eta.distance / 1000, 1)),
                ("departure", .string(DeviceToolDate.format(eta.expectedDepartureDate))),
                ("arrival", .string(DeviceToolDate.format(eta.expectedArrivalDate))),
            ])
        }
        let response: MKDirections.Response
        do { response = try await MKDirections(request: request).calculate() } catch { throw DeviceToolError("Pas d'itinéraire trouvé : \(error.localizedDescription)") }
        guard let r = response.routes.first else { throw DeviceToolError("Pas d'itinéraire trouvé.") }
        let departure = request.departureDate ?? request.arrivalDate.map { $0.addingTimeInterval(-r.expectedTravelTime) } ?? Date()
        let steps = r.steps.filter { !$0.instructions.isEmpty && $0.distance >= 300 }.prefix(12).map { s in
            JSONValue.object(["instruction": .string(s.instructions), "distanceKm": .rounded(s.distance / 1000, 1)])
        }
        return Self.merge(base, [
            ("via", .str(r.name.isEmpty ? nil : r.name)),
            ("durationMinutes", .number((r.expectedTravelTime / 60).rounded())),
            ("distanceKm", .rounded(r.distance / 1000, 1)),
            ("departure", .string(DeviceToolDate.format(departure))),
            ("arrival", .string(DeviceToolDate.format(departure.addingTimeInterval(r.expectedTravelTime)))),
            ("advisories", r.advisoryNotices.isEmpty ? nil : .array(r.advisoryNotices.map { .string($0) })),
            ("steps", .array(Array(steps))),
        ])
    }

    private static func merge(_ a: [(String, JSONValue?)], _ b: [(String, JSONValue?)]) -> JSONValue {
        var o: [String: JSONValue] = [:]
        for (k, v) in a + b { if let v { o[k] = v } }
        return .object(o)
    }
}
