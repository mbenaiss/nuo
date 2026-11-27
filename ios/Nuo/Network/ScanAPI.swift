import SwiftUI

/// What a scanned code is, decided by the gateway (`GET /api/scan/:code`) or chosen by the user.
enum ScanKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case food, cosmetic, parcel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .food: String(localized: "Food")
        case .cosmetic: String(localized: "Cosmetic")
        case .parcel: String(localized: "Parcel")
        }
    }

    var symbol: String {
        switch self {
        case .food: "fork.knife"
        case .cosmetic: "drop.fill"
        case .parcel: "shippingbox.fill"
        }
    }
}

enum IngredientRisk: String, Codable, Sendable {
    case high, moderate, low, none

    var label: String {
        switch self {
        case .high: String(localized: "High risk")
        case .moderate: String(localized: "Moderate risk")
        case .low: String(localized: "Low risk")
        case .none: String(localized: "No risk")
        }
    }

    var color: Color {
        switch self {
        case .high: Color(hex: 0xE63E11)
        case .moderate: Color(hex: 0xEE8100)
        case .low: Color(hex: 0xF5C000)
        case .none: Color(hex: 0x1E8C4E)
        }
    }

    var rank: Int {
        switch self {
        case .high: 3
        case .moderate: 2
        case .low: 1
        case .none: 0
        }
    }
}

struct CosmeticIngredient: Codable, Hashable, Sendable {
    var name: String
    var risk: IngredientRisk
    var reason: String?
}

struct CosmeticRiskCounts: Codable, Hashable, Sendable {
    var high: Int
    var moderate: Int
    var low: Int
}

struct CosmeticAnalysis: Codable, Hashable, Sendable {
    /// Absent when Open Beauty Facts has no ingredient list.
    var score: Int?
    var verdict: String
    var ingredients: [CosmeticIngredient]
    var counts: CosmeticRiskCounts
}

struct CosmeticProduct: Codable, Hashable, Sendable {
    var barcode: String
    var name: String
    var brand: String?
    var imageUrl: String?
    var quantity: String?
    var labels: [String]
    var periodAfterOpening: String?
    var analysis: CosmeticAnalysis
    var url: String
    /// openbeautyfacts, inciapi, upcitemdb, openproductsfacts or photo (a list the user photographed).
    var source: String?
}

struct FoodScanSummary: Codable, Hashable, Sendable {
    var barcode: String
    var name: String
    var brand: String?
}

struct TrackingEvent: Codable, Hashable, Sendable {
    var at: Date?
    var label: String
    var location: String?
}

/// A row of the `colis` collection, as `GET /api/parcels` returns it.
struct Parcel: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var number: String
    var label: String?
    var carrier: String?
    var carrierName: String?
    var status: String
    var statusLabel: String
    var lastEvent: TrackingEvent?
    var events: [TrackingEvent]
    /// YYYY-MM-DD.
    var estimatedDelivery: String?
    var deliveredAt: Date?
    var url: String
    var checkedAt: Date?
    var error: String?
}

struct ParcelDetection: Codable, Hashable, Sendable {
    var number: String
    var carrier: String?
    var carrierName: String?
    var url: String
    var tracked: Parcel?
}

struct ScanResult: Codable, Hashable, Sendable {
    var code: String
    /// food, cosmetic, parcel or unknown (then `candidates` says what to offer).
    var kind: String
    var candidates: [ScanKind]
    var food: FoodScanSummary?
    var cosmetic: CosmeticProduct?
    var parcel: ParcelDetection?
    var error: String?

    var scanKind: ScanKind? { ScanKind(rawValue: kind) }
}

struct ParcelList: Codable, Sendable {
    var trackingConfigured: Bool
    var parcels: [Parcel]
}

enum ParcelStatusStyle {
    static func symbol(_ status: String) -> String {
        switch status {
        case "delivered": "checkmark.seal.fill"
        case "out_for_delivery": "box.truck.fill"
        case "available_for_pickup": "building.2.fill"
        case "in_transit", "info_received": "shippingbox.fill"
        case "exception": "exclamationmark.triangle.fill"
        case "returned": "arrow.uturn.backward.circle.fill"
        default: "clock.fill"
        }
    }

    static func color(_ status: String) -> Color {
        switch status {
        case "delivered": Color.good
        case "out_for_delivery": Color(hex: 0xA855F7)
        case "available_for_pickup": Color(hex: 0xF97316)
        case "in_transit", "info_received": Color(hex: 0x3B82F6)
        case "exception": Color.bad
        default: Color.text2
        }
    }
}

/// Scanning and parcels; separate from `NuoAPI` so the demo backend opts in here.
protocol NuoScanAPI: Sendable {
    func scan(code: String, symbology: String?, kind: ScanKind?) async throws -> ScanResult
    func parcels(includeDone: Bool) async throws -> ParcelList
    /// Adds the number (or renames the parcel already tracked with it) and asks the carrier right away.
    func trackParcel(number: String, label: String?) async throws -> Parcel
    func refreshParcel(id: String) async throws -> Parcel
    func archiveParcel(id: String) async throws
    /// A photographed ingredient list: analysed, and kept by the gateway for the next scan of the same code.
    func rememberIngredients(code: String, ingredients: String, name: String?) async throws -> ScanResult
}

extension NuoClient: NuoScanAPI {
    func scan(code: String, symbology: String?, kind: ScanKind?) async throws -> ScanResult {
        let segment = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? code
        var query: [String] = []
        if let symbology, let value = symbology.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) { query.append("symbology=\(value)") }
        if let kind { query.append("kind=\(kind.rawValue)") }
        return try await request("GET", "/api/scan/\(segment)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&")))
    }

    func parcels(includeDone: Bool) async throws -> ParcelList {
        try await request("GET", includeDone ? "/api/parcels?all=1" : "/api/parcels")
    }

    func trackParcel(number: String, label: String?) async throws -> Parcel {
        struct Body: Encodable { let number: String; let label: String? }
        return try await request("POST", "/api/parcels", body: Body(number: number, label: label))
    }

    func refreshParcel(id: String) async throws -> Parcel {
        try await request("POST", "/api/parcels/\(id)/refresh", body: Optional<String>.none)
    }

    func archiveParcel(id: String) async throws { try await send("DELETE", "/api/parcels/\(id)") }

    func rememberIngredients(code: String, ingredients: String, name: String?) async throws -> ScanResult {
        struct Body: Encodable { let ingredients: String; let name: String? }
        let segment = code.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) ?? code
        return try await request("POST", "/api/scan/\(segment)/ingredients", body: Body(ingredients: ingredients, name: name))
    }
}
