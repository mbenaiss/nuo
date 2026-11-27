import Foundation

enum ProductLookupError: Error, Equatable {
    case notFound
    case network
}

/// Reads products from Open Food Facts with an in-memory and a small on-disk cache.
actor OpenFoodFactsClient {
    static let shared = OpenFoodFactsClient()

    private static let fields = [
        "code", "product_name", "product_name_fr", "generic_name_fr", "brands", "image_front_url", "image_url", "quantity",
        "serving_size", "serving_quantity", "nutriscore_grade", "nutriscore_data", "nova_group", "ecoscore_grade", "nutriments",
        "additives_tags", "allergens_tags", "ingredients_text_fr", "ingredients_text", "labels_tags", "categories", "categories_tags",
        "manufacturing_places", "manufacturing_places_tags", "origins", "origins_tags", "origin_fr", "emb_codes", "countries_tags",
    ].joined(separator: ",")
    private static let diskTTL: TimeInterval = 7 * 86400
    private static let diskLimit = 60

    private var memory: [String: FoodProduct] = [:]
    private var inFlight: [String: Task<FoodProduct, Error>] = [:]
    private let session: URLSession
    private let directory: URL?

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 12
        config.httpAdditionalHeaders = ["User-Agent": "Nuo/0.1 (personal app)"]
        session = URLSession(configuration: config)
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("off", isDirectory: true)
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        if ProcessInfo.processInfo.arguments.contains("-demo") {
            for (code, json) in DemoProducts.fixtures {
                if let product = try? FoodProduct.decode(Data(json.utf8), barcode: code) { memory[code] = product }
            }
        }
    }

    /// Synchronous peek used to render a card without a loading flash when the product is already known.
    func cached(_ barcode: String) -> FoodProduct? { memory[barcode] }

    func product(_ barcode: String) async throws -> FoodProduct {
        if let product = memory[barcode] { return product }
        if let product = readDisk(barcode) {
            memory[barcode] = product
            return product
        }
        if let task = inFlight[barcode] { return try await task.value }
        let task = Task { try await fetch(barcode) }
        inFlight[barcode] = task
        defer { inFlight[barcode] = nil }
        let product = try await task.value
        memory[barcode] = product
        return product
    }

    private func fetch(_ barcode: String) async throws -> FoodProduct {
        guard let url = URL(string: "https://world.openfoodfacts.org/api/v2/product/\(barcode).json?fields=\(Self.fields)") else {
            throw ProductLookupError.notFound
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            throw ProductLookupError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { throw ProductLookupError.notFound }
        guard (200..<300).contains(status) else { throw ProductLookupError.network }
        guard let product = try? FoodProduct.decode(data, barcode: barcode) else { throw ProductLookupError.notFound }
        writeDisk(barcode, data: data)
        return product
    }

    private func fileURL(_ barcode: String) -> URL? {
        directory?.appendingPathComponent("\(barcode).json")
    }

    private func readDisk(_ barcode: String) -> FoodProduct? {
        guard let url = fileURL(barcode),
              let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate,
              Date().timeIntervalSince(modified) < Self.diskTTL,
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? FoodProduct.decode(data, barcode: barcode)
    }

    private func writeDisk(_ barcode: String, data: Data) {
        guard let directory, let url = fileURL(barcode) else { return }
        try? data.write(to: url, options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        guard files.count > Self.diskLimit else { return }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for file in sorted.prefix(files.count - Self.diskLimit) { try? FileManager.default.removeItem(at: file) }
    }
}
