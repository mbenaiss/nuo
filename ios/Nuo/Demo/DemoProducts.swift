import Foundation

/// An invented product answered from memory in demo mode, so product screenshots work offline. The barcode sits in the
/// in-store range (prefix 200), which no real brand uses.
enum DemoProducts {
    static let darkChocolate = "2004815300629"

    static var fixtures: [String: String] {
        let name = String(localized: "Mira Extra Dark 70%")
        let ingredients = String(localized: "Cocoa mass, sugar, cocoa butter, emulsifier (sunflower lecithin), natural vanilla flavoring. Cocoa: 70% minimum. May contain milk and tree nuts.")
        return [
            darkChocolate: """
            {"code":"\(darkChocolate)","status":1,"product":{"code":"\(darkChocolate)","product_name":"\(name)","brands":"Mira Cacao",
            "quantity":"100 g","serving_size":"20g","serving_quantity":20,"nutriscore_grade":"e",
            "nutriscore_data":{"score":24,"is_beverage":0,"grade":"e"},"nova_group":3,"ecoscore_grade":"d",
            "nutriments":{"energy-kcal_100g":584,"energy_100g":2443,"fat_100g":42,"saturated-fat_100g":26,"carbohydrates_100g":34,
            "sugars_100g":28,"fiber_100g":11,"proteins_100g":8.1,"salt_100g":0.02},
            "additives_tags":["en:e322"],"allergens_tags":["en:milk","en:nuts"],
            "ingredients_text":"\(ingredients)",
            "labels_tags":["en:pure-cocoa-butter"],"categories":"Dark chocolates",
            "countries_tags":["en:france"],"categories_tags":["en:snacks","en:sweet-snacks","en:cocoa-and-its-products","en:chocolates","en:dark-chocolates"]}}
            """,
        ]
    }
}
