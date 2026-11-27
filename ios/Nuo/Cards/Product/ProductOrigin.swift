import Foundation

/// Where a product comes from, as far as Open Food Facts knows. Most products only fill some of these.
struct ProductOrigin: Hashable, Sendable {
    var manufacturing: [Place]
    var ingredients: [Place]
    /// Country of the packer, read from the EU health mark ("FR 72.264.001 CE").
    var packaging: Place?
    /// Where the product is sold: shown only when nothing says where it is from.
    var soldIn: [Place]

    struct Place: Hashable, Sendable {
        var name: String
        var regionCode: String?

        var flag: String? {
            guard let code = regionCode, code.count == 2 else { return nil }
            let scalars = code.uppercased().unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }
            return String(String.UnicodeScalarView(scalars))
        }

        var label: String { [flag, name].compactMap { $0 }.joined(separator: " ") }
    }

    var isKnown: Bool { !manufacturing.isEmpty || !ingredients.isEmpty || packaging != nil }

    /// The country to show in compact places (product card): manufacturing first.
    var primary: Place? { manufacturing.first ?? packaging ?? ingredients.first }

    var isEmpty: Bool { !isKnown && soldIn.isEmpty }
}

extension ProductOrigin {
    init?(manufacturing: String?, manufacturingTags: [String]?, origins: String?, originTags: [String]?, embCodes: String?, countryTags: [String]?, labelTags: [String] = []) {
        var made = Self.places(text: manufacturing, tags: manufacturingTags)
        if made.isEmpty, let label = labelTags.lazy.compactMap(Self.madeInLabel).first { made = [label] }
        let from = Self.places(text: origins, tags: originTags)
        let packer = Self.packerCountry(embCodes)
        let sold = (countryTags ?? []).compactMap(Self.place(tag:))
        self.init(manufacturing: made, ingredients: from, packaging: packer, soldIn: Array(sold.prefix(4)))
        if isEmpty { return nil }
    }

    /// Free text is in the product's language and often more precise ("Bretagne, France"); tags give the flag.
    private static func places(text: String?, tags: [String]?) -> [Place] {
        let fromTags = (tags ?? []).compactMap(place(tag:))
        if !fromTags.isEmpty { return Array(fromTags.prefix(4)) }
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return text.split(whereSeparator: { $0 == "," || $0 == ";" }).prefix(4).compactMap { part in
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            let code = Countries.code(forName: name)
            return Place(name: code.flatMap(Countries.displayName) ?? name, regionCode: code)
        }
    }

    private static func place(tag: String) -> Place? {
        let value = tag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tag
        guard !["unknown", "world", "european-union"].contains(value) else {
            return value == "european-union" ? Place(name: String(localized: "European Union"), regionCode: "EU") : nil
        }
        let code = Countries.code(forName: value.replacingOccurrences(of: "-", with: " "))
        return Place(name: code.flatMap(Countries.displayName) ?? value.replacingOccurrences(of: "-", with: " ").capitalized, regionCode: code)
    }

    /// Labels such as "en:made-in-france" or "fr:fabrique-en-france" when the manufacturing place is not filled.
    private static func madeInLabel(_ tag: String) -> Place? {
        let value = tag.split(separator: ":", maxSplits: 1).last.map(String.init) ?? tag
        for prefix in ["made-in-", "fabrique-en-", "produit-en-"] where value.hasPrefix(prefix) {
            return place(tag: String(value.dropFirst(prefix.count)))
        }
        return nil
    }

    private static func packerCountry(_ codes: String?) -> Place? {
        guard let first = codes?.split(separator: ",").first?.trimmingCharacters(in: .whitespaces),
              first.count > 3, first.dropFirst(2).first == " "
        else { return nil }
        let code = String(first.prefix(2)).uppercased()
        guard let name = Countries.displayName(code) else { return nil }
        return Place(name: name, regionCode: code)
    }
}

private enum Countries {
    private static let french = Locale(identifier: "fr_FR")
    private static let english = Locale(identifier: "en_US")

    private static let byName: [String: String] = {
        var map: [String: String] = [:]
        for region in Locale.Region.isoRegions where region.identifier.count == 2 {
            let code = region.identifier
            for locale in [english, french] {
                if let name = locale.localizedString(forRegionCode: code) { map[normalize(name)] = code }
            }
        }
        map["uk"] = "GB"
        map["usa"] = "US"
        return map
    }()

    static func code(forName name: String) -> String? { byName[normalize(name)] }

    static func displayName(_ code: String) -> String? { Locale.current.localizedString(forRegionCode: code) }

    private static func normalize(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
