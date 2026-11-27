import Foundation

/// A product from Open Food Facts, reduced to what the product sheet shows.
struct FoodProduct: Hashable, Sendable {
    var barcode: String
    var name: String
    var brand: String?
    var imageURL: String?
    var quantity: String?
    var servingSize: String?
    var servingGrams: Double?
    var nutriscoreGrade: String?
    var nutriscoreScore: Double?
    var isBeverage: Bool
    var novaGroup: Int?
    var greenScoreGrade: String?
    var nutriments: Nutriments
    var additiveTags: [String]
    var allergenTags: [String]
    var ingredients: String?
    var labelTags: [String]
    var categories: String?
    var origin: ProductOrigin? = nil

    struct Nutriments: Hashable, Sendable {
        var energyKcal: Double?
        var fat: Double?
        var saturatedFat: Double?
        var carbohydrates: Double?
        var sugars: Double?
        var fiber: Double?
        var proteins: Double?
        var salt: Double?
    }

    var isOrganic: Bool {
        labelTags.contains { tag in
            let value = tag.lowercased()
            return value.hasSuffix(":organic") || value.hasSuffix(":bio") || value.contains("eu-organic") || value.contains("ab-agriculture-biologique")
        }
    }

    /// Unit shown next to per-100 values.
    var unit: String { isBeverage ? "ml" : "g" }
}

extension FoodProduct {
    static func decode(_ data: Data, barcode: String) throws -> FoodProduct? {
        let response = try JSONDecoder().decode(OFFResponse.self, from: data)
        guard let raw = response.product, response.status != 0 else { return nil }
        let name = [raw.product_name_fr, raw.product_name, raw.generic_name_fr].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let n = raw.nutriments ?? [:]
        let categories = raw.categories_tags ?? []
        let beverage = raw.nutriscore_data?.is_beverage.map { $0 != 0 }
            ?? categories.contains { $0.hasSuffix(":beverages") || $0.hasSuffix(":drinks") }
        return FoodProduct(
            barcode: raw.code ?? response.code ?? barcode,
            name: name.map(Self.tidyName) ?? String(localized: "Product \(barcode)"),
            brand: raw.brands?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) },
            imageURL: raw.image_front_url ?? raw.image_url,
            quantity: raw.quantity?.nilIfEmpty,
            servingSize: raw.serving_size?.nilIfEmpty,
            servingGrams: raw.serving_quantity?.value,
            nutriscoreGrade: Self.grade(raw.nutriscore_grade),
            nutriscoreScore: raw.nutriscore_data?.score,
            isBeverage: beverage,
            novaGroup: raw.nova_group?.value.map { Int($0) },
            greenScoreGrade: Self.grade(raw.ecoscore_grade),
            nutriments: Nutriments(
                energyKcal: n["energy-kcal_100g"]?.value ?? n["energy_100g"]?.value.map { $0 / 4.184 },
                fat: n["fat_100g"]?.value,
                saturatedFat: n["saturated-fat_100g"]?.value,
                carbohydrates: n["carbohydrates_100g"]?.value,
                sugars: n["sugars_100g"]?.value,
                fiber: n["fiber_100g"]?.value,
                proteins: n["proteins_100g"]?.value,
                salt: n["salt_100g"]?.value),
            additiveTags: raw.additives_tags ?? [],
            allergenTags: raw.allergens_tags ?? [],
            ingredients: (raw.ingredients_text_fr?.nilIfEmpty ?? raw.ingredients_text?.nilIfEmpty)?.trimmingCharacters(in: .whitespacesAndNewlines),
            labelTags: raw.labels_tags ?? [],
            categories: raw.categories?.nilIfEmpty,
            origin: ProductOrigin(
                manufacturing: raw.manufacturing_places, manufacturingTags: raw.manufacturing_places_tags,
                origins: raw.origins?.nilIfEmpty ?? raw.origin_fr, originTags: raw.origins_tags,
                embCodes: raw.emb_codes, countryTags: raw.countries_tags, labelTags: raw.labels_tags ?? []))
    }

    private static func grade(_ value: String?) -> String? {
        guard let value = value?.lowercased(), !["unknown", "not-applicable", ""].contains(value) else { return nil }
        return value
    }

    /// OFF names are often typed in lowercase ("Poulain noir extra").
    private static func tidyName(_ name: String) -> String {
        guard !name.dropFirst().contains(where: \.isUppercase) else { return name }
        let small: Set<String> = ["de", "du", "des", "la", "le", "les", "au", "aux", "et", "à", "en", "d'", "l'"]
        return name.split(separator: " ").enumerated().map { index, word in
            index > 0 && small.contains(word.lowercased()) ? String(word) : word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}

private struct OFFResponse: Decodable {
    var code: String?
    var status: Int?
    var product: OFFProduct?
}

private struct OFFProduct: Decodable {
    var code: String?
    var product_name: String?
    var product_name_fr: String?
    var generic_name_fr: String?
    var brands: String?
    var image_front_url: String?
    var image_url: String?
    var quantity: String?
    var serving_size: String?
    var serving_quantity: LenientNumber?
    var nutriscore_grade: String?
    var nutriscore_data: NutriscoreData?
    var nova_group: LenientNumber?
    var ecoscore_grade: String?
    var nutriments: [String: LenientNumber]?
    var additives_tags: [String]?
    var allergens_tags: [String]?
    var ingredients_text_fr: String?
    var ingredients_text: String?
    var labels_tags: [String]?
    var categories: String?
    var categories_tags: [String]?
    var manufacturing_places: String?
    var manufacturing_places_tags: [String]?
    var origins: String?
    var origins_tags: [String]?
    var origin_fr: String?
    var emb_codes: String?
    var countries_tags: [String]?

    struct NutriscoreData: Decodable {
        var score: Double?
        var is_beverage: Int?

        enum CodingKeys: String, CodingKey { case score, is_beverage }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            score = (try? c.decode(LenientNumber.self, forKey: .score))?.value
            is_beverage = (try? c.decode(LenientNumber.self, forKey: .is_beverage))?.value.map { Int($0) }
        }
    }
}

/// OFF mixes numbers, numeric strings and stray text in the same fields.
private struct LenientNumber: Decodable {
    var value: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let number = try? c.decode(Double.self) {
            value = number
        } else if let text = try? c.decode(String.self) {
            value = Double(text.replacingOccurrences(of: ",", with: ".").filter { $0.isNumber || $0 == "." })
        } else {
            value = nil
        }
    }
}
