import CoreLocation
import Foundation
import MapKit

/// MapKit travel times for « Partir maintenant », always from a place the user saved: the device position is never
/// read (no location manager, no `forCurrentLocation`). ETAs and geocoded event places are cached on disk.
@MainActor
final class TravelEstimator {
    static let shared = TravelEstimator()

    enum Outcome: Equatable {
        case eta(seconds: Int, destination: GeoPoint)
        /// Origin and destination are the same place.
        case tooClose
        case unknown
    }

    static let closeDistance: CLLocationDistance = 300
    /// MapKit throttles apps that send too many requests in a short time.
    private static let requestsPerPass = 12

    private struct Entry: Codable {
        var seconds: Int
        var computedAt: Date
    }

    private struct Cache: Codable {
        var etas: [String: Entry] = [:]
        var places: [String: GeoPoint] = [:]
    }

    private var cache: Cache
    private var requests = 0

    private static var url: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("travel-cache.json")
    }

    private init() {
        cache = (try? Data(contentsOf: Self.url)).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } ?? Cache()
    }

    /// Starts a scheduling pass: resets the request allowance.
    func beginPass() { requests = 0 }

    /// The last ETA computed for this trip, however old.
    func cachedSeconds(item: AgendaItem, origin: Place, mode: TravelMode) -> Int? {
        guard let destination = knownDestination(of: item) else { return nil }
        return cache.etas[Self.key(origin: origin, destination: destination, mode: mode, start: item.start)]?.seconds
    }

    /// ETA from `origin` to the event's place, leaving so as to arrive `margin` before the start (traffic included
    /// for driving). Recomputed when older than 6 h, or 20 min in the last 3 h before the event.
    func estimate(item: AgendaItem, origin: Place, mode: TravelMode, margin: TimeInterval, now: Date = Date()) async -> Outcome {
        guard let destination = await destination(of: item, near: origin) else { return .unknown }
        let from = CLLocation(latitude: origin.lat, longitude: origin.lon)
        let to = CLLocation(latitude: destination.lat, longitude: destination.lon)
        if from.distance(from: to) < Self.closeDistance { return .tooClose }
        let key = Self.key(origin: origin, destination: destination, mode: mode, start: item.start)
        let maxAge: TimeInterval = item.start.timeIntervalSince(now) > 3 * 3600 ? 6 * 3600 : 20 * 60
        let known = cache.etas[key]
        if let known, now.timeIntervalSince(known.computedAt) < maxAge { return .eta(seconds: known.seconds, destination: destination) }
        guard requests < Self.requestsPerPass else { return known.map { .eta(seconds: $0.seconds, destination: destination) } ?? .unknown }
        requests += 1
        let guess = TimeInterval(known?.seconds ?? item.travelTimeSec ?? 1800)
        let request = MKDirections.Request()
        request.source = MKMapItem(location: from, address: nil)
        request.destination = MKMapItem(location: to, address: nil)
        request.transportType = mode.transportType
        request.departureDate = max(now, item.start.addingTimeInterval(-guess - margin))
        do {
            let response = try await MKDirections(request: request).calculateETA()
            let seconds = Int(response.expectedTravelTime.rounded())
            cache.etas[key] = Entry(seconds: seconds, computedAt: now)
            save(now: now)
            return .eta(seconds: seconds, destination: destination)
        } catch {
            return known.map { .eta(seconds: $0.seconds, destination: destination) } ?? .unknown
        }
    }

    private func knownDestination(of item: AgendaItem) -> GeoPoint? {
        if let point = item.coordinates { return point }
        return item.location.flatMap { cache.places[$0] }
    }

    /// The event's coordinates, else its address searched around the origin place.
    private func destination(of item: AgendaItem, near origin: Place) async -> GeoPoint? {
        if let point = knownDestination(of: item) { return point }
        guard let location = item.location?.trimmingCharacters(in: .whitespacesAndNewlines), !location.isEmpty,
              requests < Self.requestsPerPass else { return nil }
        requests += 1
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = location
        request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: origin.lat, longitude: origin.lon),
                                            latitudinalMeters: 80_000, longitudinalMeters: 80_000)
        guard let response = try? await MKLocalSearch(request: request).start(), let found = response.mapItems.first else { return nil }
        let point = GeoPoint(lat: found.location.coordinate.latitude, lon: found.location.coordinate.longitude)
        if cache.places.count > 300 { cache.places.removeAll() }
        cache.places[location] = point
        save(now: Date())
        return point
    }

    private static func key(origin: Place, destination: GeoPoint, mode: TravelMode, start: Date) -> String {
        let slot = Int(start.timeIntervalSince1970 / 900)
        let from = String(format: "%.4f,%.4f", origin.lat, origin.lon), to = String(format: "%.4f,%.4f", destination.lat, destination.lon)
        return "\(from)|\(to)|\(mode.rawValue)|\(slot)"
    }

    private func save(now: Date) {
        cache.etas = cache.etas.filter { now.timeIntervalSince($0.value.computedAt) < 3 * 86400 }
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: Self.url, options: .atomic)
    }
}
