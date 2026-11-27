import SwiftUI

enum Verdict {
    case excellent, good, poor, bad

    init(score: Int) {
        switch score {
        case 75...: self = .excellent
        case 50..<75: self = .good
        case 25..<50: self = .poor
        default: self = .bad
        }
    }

    var label: String {
        switch self {
        case .excellent: String(localized: "Excellent")
        case .good: String(localized: "Good")
        case .poor: String(localized: "Poor")
        case .bad: String(localized: "Bad")
        }
    }

    var color: Color {
        switch self {
        case .excellent: Color(hex: 0x1E8C4E)
        case .good: Color(hex: 0x5DBB46)
        case .poor: Color(hex: 0xF08A24)
        case .bad: Color(hex: 0xE5484D)
        }
    }
}

/// Four-step quality scale shared by nutrient rows, gauges and additive risks.
enum QualityLevel: Int, Comparable {
    case excellent, good, poor, bad

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var color: Color {
        switch self {
        case .excellent: Color(hex: 0x1E8C4E)
        case .good: Color(hex: 0x6CC04A)
        case .poor: Color(hex: 0xF29D38)
        case .bad: Color(hex: 0xE5484D)
        }
    }

    var isDefect: Bool { self >= .poor }
}

struct NutrientAssessment: Identifiable {
    enum Kind: String {
        case energy, sugars, saturatedFat, salt, fiber, proteins

        var title: String {
            switch self {
            case .energy: String(localized: "Calories")
            case .sugars: String(localized: "Sugars")
            case .saturatedFat: String(localized: "Saturated fat")
            case .salt: String(localized: "Salt")
            case .fiber: String(localized: "Fiber")
            case .proteins: String(localized: "Protein")
            }
        }

        var symbol: String {
            switch self {
            case .energy: "flame.fill"
            case .sugars: "cube.fill"
            case .saturatedFat: "drop.fill"
            case .salt: "circle.hexagongrid.fill"
            case .fiber: "leaf.fill"
            case .proteins: "fish.fill"
            }
        }

        var unit: String { self == .energy ? "kcal" : "g" }

        /// Positive nutrients: more is better, the gauge runs red to green.
        var isPositive: Bool { self == .fiber || self == .proteins }
    }

    let kind: Kind
    let value: Double
    /// Three cut points separating the four levels, ascending.
    let thresholds: [Double]
    let level: QualityLevel
    let label: String

    var id: String { kind.rawValue }

    var gaugeMax: Double {
        let last = thresholds.last ?? 1
        return max(last * 1.45, value * 1.08)
    }
}

enum AdditiveRisk: Int, Comparable {
    case none, low, moderate, high

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .none: String(localized: "No risk")
        case .low: String(localized: "Low risk")
        case .moderate: String(localized: "Moderate risk")
        case .high: String(localized: "High risk")
        }
    }

    var level: QualityLevel {
        switch self {
        case .none: .excellent
        case .low: .good
        case .moderate: .poor
        case .high: .bad
        }
    }

    var penalty: Double {
        switch self {
        case .none: 0
        case .low: 8
        case .moderate: 35
        case .high: 70
        }
    }
}

struct Additive: Identifiable, Hashable {
    let code: String
    let name: String
    let risk: AdditiveRisk
    let note: String
    var id: String { code }
}

struct HealthScore {
    let total: Int
    let nutrition: Int
    let additives: Int
    let organic: Bool

    var verdict: Verdict { Verdict(score: total) }
}

struct ProductAnalysis {
    let product: FoodProduct
    let nutrients: [NutrientAssessment]
    let additives: [Additive]
    let score: HealthScore

    init(_ product: FoodProduct) {
        self.product = product
        nutrients = Self.assess(product)
        additives = Self.additives(from: product.additiveTags)
        score = Self.score(product: product, nutrients: nutrients, additives: additives)
    }

    var defects: [NutrientAssessment] { nutrients.filter { $0.level.isDefect && !$0.kind.isPositive } }
    var qualities: [NutrientAssessment] {
        nutrients.filter { !$0.level.isDefect }.sorted { $0.kind.isPositive && !$1.kind.isPositive }
    }

    var allergens: [String] {
        var seen = Set<String>()
        return product.allergenTags.compactMap { tag in
            let key = tag.split(separator: ":").last.map(String.init) ?? tag
            let name = Self.allergenNames[key] ?? key.replacingOccurrences(of: "-", with: " ").capitalized
            return seen.insert(name).inserted ? name : nil
        }
    }

    // MARK: - Nutrients

    private static func assess(_ product: FoodProduct) -> [NutrientAssessment] {
        let n = product.nutriments
        let drink = product.isBeverage
        var result: [NutrientAssessment] = []

        func add(_ kind: NutrientAssessment.Kind, _ value: Double?, _ thresholds: [Double], _ labels: [String]) {
            guard let value else { return }
            let step = thresholds.firstIndex { value < $0 } ?? 3
            let level: QualityLevel
            if kind.isPositive {
                // Low fibre or protein is not a defect worth listing: those rows only show up as qualities.
                guard step >= 2 else { return }
                level = step == 3 ? .excellent : .good
            } else {
                level = QualityLevel(rawValue: step) ?? .bad
            }
            result.append(NutrientAssessment(kind: kind, value: value, thresholds: thresholds, level: level, label: labels[min(step, labels.count - 1)]))
        }

        add(.energy, n.energyKcal, drink ? [1, 14, 35] : [160, 360, 560],
            [String(localized: "Low in calories"), String(localized: "Fairly low in calories"), String(localized: "A bit too caloric"), String(localized: "Too caloric")])
        add(.sugars, n.sugars, drink ? [1.5, 3, 7] : [9, 18, 31],
            [String(localized: "Low in sugar"), String(localized: "Small amount of sugar"), String(localized: "A bit too sweet"), String(localized: "Too sweet")])
        add(.saturatedFat, n.saturatedFat, drink ? [1, 2, 4] : [2, 4, 7],
            [String(localized: "Low in saturated fat"), String(localized: "Small amount of saturated fat"), String(localized: "A bit too much saturated fat"), String(localized: "Too much saturated fat")])
        add(.salt, n.salt, [0.46, 0.92, 1.62],
            [String(localized: "Low in salt"), String(localized: "Small amount of salt"), String(localized: "A bit too salty"), String(localized: "Too salty")])
        add(.fiber, n.fiber, [1.9, 2.8, 4.7],
            ["", "", String(localized: "Some fiber"), String(localized: "Excellent amount of fiber")])
        add(.proteins, n.proteins, [3.2, 4.8, 8],
            ["", "", String(localized: "Some protein"), String(localized: "Excellent amount of protein")])
        return result
    }

    // MARK: - Score

    private static func score(product: FoodProduct, nutrients: [NutrientAssessment], additives: [Additive]) -> HealthScore {
        let nutrition: Double
        if let fsa = product.nutriscoreScore, !product.isBeverage {
            nutrition = 100 - (fsa + 5) * 100 / 35
        } else if let grade = product.nutriscoreGrade {
            nutrition = ["a": 90, "b": 72, "c": 50, "d": 30, "e": 10][grade] ?? 50
        } else {
            let penalties = nutrients.filter { !$0.kind.isPositive }.reduce(0.0) { sum, item in
                sum + [0, 6, 18, 30][item.level.rawValue]
            }
            let bonus = nutrients.filter { $0.kind.isPositive }.reduce(0.0) { $0 + ($1.level == .excellent ? 10 : 5) }
            nutrition = 90 - penalties + bonus
        }
        let nutritionScore = min(100, max(0, nutrition))
        let additiveScore = max(0, 100 - additives.reduce(0) { $0 + $1.risk.penalty })
        var total = nutritionScore * 0.6 + additiveScore * 0.3 + (product.isOrganic ? 10 : 0)
        // A high-risk additive keeps the product out of the "Good" range whatever its nutrition.
        if additives.contains(where: { $0.risk == .high }) { total = min(total, 49) }
        return HealthScore(
            total: Int(total.rounded()), nutrition: Int(nutritionScore.rounded()), additives: Int(additiveScore.rounded()),
            organic: product.isOrganic)
    }

    // MARK: - Additives

    static func additives(from tags: [String]) -> [Additive] {
        var seen = Set<String>()
        return tags.compactMap { tag -> Additive? in
            let raw = (tag.split(separator: ":").last.map(String.init) ?? tag).lowercased()
            guard let code = baseCode(raw), seen.insert(code).inserted else { return nil }
            let display = "E" + code.dropFirst().lowercased()
            if let known = knownAdditives[code] {
                return Additive(code: display, name: known.name, risk: known.risk, note: known.note)
            }
            return Additive(code: display, name: String(localized: "Additive"), risk: .low, note: String(localized: "No known risk signal."))
        }
        .sorted { $0.risk > $1.risk }
    }

    /// "e322i" → "E322", "e150d" → "E150D": roman-numeral sub-variants share the parent's assessment.
    private static func baseCode(_ raw: String) -> String? {
        guard raw.first == "e" else { return nil }
        let digits = raw.dropFirst().prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let rest = raw.dropFirst(1 + digits.count)
        var code = "E" + digits
        if let letter = rest.first, "abcdefgh".contains(letter) { code.append(letter.uppercased()) }
        return code
    }

    private static let knownAdditives: [String: (name: String, risk: AdditiveRisk, note: String)] = [
        "E249": (String(localized: "Potassium nitrite"), .high, String(localized: "Preservative in cured meats, linked to the formation of nitrosamines.")),
        "E250": (String(localized: "Sodium nitrite"), .high, String(localized: "Preservative in cured meats, linked to the formation of nitrosamines.")),
        "E251": (String(localized: "Sodium nitrate"), .high, String(localized: "Turns into nitrites, with a risk of nitrosamines.")),
        "E252": (String(localized: "Potassium nitrate"), .high, String(localized: "Turns into nitrites, with a risk of nitrosamines.")),
        "E320": (String(localized: "BHA"), .high, String(localized: "Antioxidant classified as possibly carcinogenic (IARC 2B).")),
        "E321": (String(localized: "BHT"), .moderate, String(localized: "Antioxidant suspected of being an endocrine disruptor.")),
        "E171": (String(localized: "Titanium dioxide"), .high, String(localized: "Banned in the EU since 2022, genotoxicity not ruled out.")),
        "E150C": (String(localized: "Ammonia caramel"), .moderate, String(localized: "May contain 4-MEI, a possible carcinogen.")),
        "E150D": (String(localized: "Ammonium sulfite caramel"), .moderate, String(localized: "May contain 4-MEI, a possible carcinogen.")),
        "E951": (String(localized: "Aspartame"), .high, String(localized: "Sweetener classified as possibly carcinogenic (IARC 2B, 2023).")),
        "E950": (String(localized: "Acesulfame K"), .moderate, String(localized: "Sweetener, effects on the gut microbiome under study.")),
        "E955": (String(localized: "Sucralose"), .moderate, String(localized: "Sweetener, compounds of concern when cooked.")),
        "E954": (String(localized: "Saccharin"), .moderate, String(localized: "Sweetener, effects on the gut microbiome under study.")),
        "E621": (String(localized: "Monosodium glutamate"), .moderate, String(localized: "Flavor enhancer, may encourage overeating.")),
        "E407": (String(localized: "Carrageenans"), .moderate, String(localized: "Thickener, suspected of causing gut inflammation.")),
        "E466": (String(localized: "Carboxymethylcellulose"), .moderate, String(localized: "Emulsifier, alters the gut microbiome.")),
        "E433": (String(localized: "Polysorbate 80"), .moderate, String(localized: "Emulsifier, alters the gut microbiome.")),
        "E102": (String(localized: "Tartrazine"), .moderate, String(localized: "Azo dye, linked to hyperactivity in children.")),
        "E110": (String(localized: "Sunset Yellow"), .moderate, String(localized: "Azo dye, linked to hyperactivity in children.")),
        "E129": (String(localized: "Allura Red AC"), .moderate, String(localized: "Azo dye, linked to hyperactivity in children.")),
        "E211": (String(localized: "Sodium benzoate"), .moderate, String(localized: "Preservative, can form benzene with vitamin C.")),
        "E220": (String(localized: "Sulfur dioxide"), .moderate, String(localized: "Sulfite, an allergen for sensitive people.")),
        "E338": (String(localized: "Phosphoric acid"), .low, String(localized: "Acidifier in sodas, best limited.")),
        "E450": (String(localized: "Diphosphates"), .low, String(localized: "Added phosphates are best limited.")),
        "E452": (String(localized: "Polyphosphates"), .low, String(localized: "Added phosphates are best limited.")),
        "E471": (String(localized: "Mono- and diglycerides of fatty acids"), .low, String(localized: "Common emulsifier, limited data.")),
        "E1442": (String(localized: "Hydroxypropyl distarch phosphate"), .low, String(localized: "Modified starch, limited data.")),
        "E322": (String(localized: "Lecithins"), .none, String(localized: "Natural emulsifier (soy, sunflower).")),
        "E330": (String(localized: "Citric acid"), .none, String(localized: "Natural acidifier from citrus fruit.")),
        "E300": (String(localized: "Ascorbic acid"), .none, String(localized: "Vitamin C, antioxidant.")),
        "E306": (String(localized: "Tocopherols"), .none, String(localized: "Vitamin E, antioxidant.")),
        "E440": (String(localized: "Pectins"), .none, String(localized: "Natural gelling agent from fruit.")),
        "E412": (String(localized: "Guar gum"), .none, String(localized: "Plant-based thickener.")),
        "E415": (String(localized: "Xanthan gum"), .none, String(localized: "Thickener obtained by fermentation.")),
        "E500": (String(localized: "Sodium carbonates"), .none, String(localized: "Raising agent.")),
        "E503": (String(localized: "Ammonium carbonates"), .none, String(localized: "Raising agent.")),
        "E160A": (String(localized: "Carotenoids"), .none, String(localized: "Natural coloring.")),
    ]

    private static let allergenNames: [String: String] = [
        "milk": String(localized: "Milk"), "soybeans": String(localized: "Soy"), "gluten": String(localized: "Gluten"), "nuts": String(localized: "Tree nuts"), "eggs": String(localized: "Eggs"), "fish": String(localized: "Fish"),
        "peanuts": String(localized: "Peanuts"), "sesame-seeds": String(localized: "Sesame"), "celery": String(localized: "Celery"), "mustard": String(localized: "Mustard"), "lupin": String(localized: "Lupin"),
        "molluscs": String(localized: "Molluscs"), "crustaceans": String(localized: "Crustaceans"), "sulphur-dioxide-and-sulphites": String(localized: "Sulfites"),
    ]
}

/// Macros for a given portion, shared by the card, the sheet and the log prompt.
struct PortionMacros {
    let grams: Double
    let kcal: Double?
    let proteins: Double?
    let carbs: Double?
    let fat: Double?
    let sugars: Double?

    init(_ product: FoodProduct, grams: Double) {
        let n = product.nutriments
        let factor = grams / 100
        self.grams = grams
        kcal = n.energyKcal.map { $0 * factor }
        proteins = n.proteins.map { $0 * factor }
        carbs = n.carbohydrates.map { $0 * factor }
        fat = n.fat.map { $0 * factor }
        sugars = n.sugars.map { $0 * factor }
    }

    func logPrompt(for product: FoodProduct) -> String {
        let brand = product.brand.map { " (\($0))" } ?? ""
        var parts: [String] = []
        if let kcal { parts.append("\(Int(kcal.rounded())) kcal") }
        if let proteins { parts.append("P \(NutrientFormat.grams(proteins, locale: Locale(identifier: "fr_FR"))) g") }
        if let carbs { parts.append("G \(NutrientFormat.grams(carbs, locale: Locale(identifier: "fr_FR"))) g") }
        if let fat { parts.append("L \(NutrientFormat.grams(fat, locale: Locale(identifier: "fr_FR"))) g") }
        let macros = parts.isEmpty ? "" : " : " + parts.joined(separator: ", ")
        return "J'ai mangé \(NutrientFormat.grams(grams, locale: Locale(identifier: "fr_FR"))) \(product.unit) de \(product.name)\(brand), code-barres \(product.barcode)\(macros). Enregistre-le."
    }
}

enum NutrientFormat {
    static func grams(_ value: Double, locale: Locale = .current) -> String {
        let digits = value >= 10 ? 0 : value >= 0.1 ? 1 : 2
        return value.formatted(.number.precision(.fractionLength(0...digits)).locale(locale))
    }

    static func value(_ value: Double, kind: NutrientAssessment.Kind) -> String {
        kind == .energy ? "\(Int(value.rounded())) kcal" : "\(grams(value)) g"
    }
}
