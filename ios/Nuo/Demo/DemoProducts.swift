import Foundation

/// Invented products answered from memory in demo mode, so product screenshots work offline. The barcodes sit in the
/// in-store range (prefix 200), which no real brand uses.
enum DemoProducts {
    static let darkChocolate = "2004815300629"
    static let peachIcedTea = "2007315004189"

    /// Serving the bot logs by default: a square of chocolate is weighed, a drink is the whole can.
    static func portion(_ barcode: String) -> Int {
        barcode == peachIcedTea ? 330 : 20
    }

    static var fixtures: [String: String] {
        let name = String(localized: "Mira Extra Dark 70%")
        let ingredients = String(localized: "Cocoa mass, sugar, cocoa butter, emulsifier (sunflower lecithin), natural vanilla flavoring. Cocoa: 70% minimum. May contain milk and tree nuts.")
        let teaName = String(localized: "Orchard Peach Iced Tea")
        let teaIngredients = String(localized: "Water, sugar, peach juice from concentrate (2%), acidifier (citric acid), black tea extract (0.12%), natural peach flavoring, antioxidant (ascorbic acid).")
        return [
            peachIcedTea: """
            {"code":"\(peachIcedTea)","status":1,"product":{"code":"\(peachIcedTea)","product_name":"\(teaName)","brands":"Orchard Fizz",
            "quantity":"330 ml","serving_size":"330 ml","serving_quantity":330,"nutriscore_grade":"d",
            "nutriscore_data":{"score":9,"is_beverage":1,"grade":"d"},"nova_group":4,"ecoscore_grade":"c",
            "nutriments":{"energy-kcal_100g":32,"energy_100g":134,"fat_100g":0,"saturated-fat_100g":0,"carbohydrates_100g":7.8,
            "sugars_100g":7.6,"fiber_100g":0,"proteins_100g":0,"salt_100g":0.02},
            "additives_tags":["en:e330","en:e300"],"allergens_tags":[],
            "ingredients_text":"\(teaIngredients)",
            "labels_tags":[],"categories":"Iced teas",
            "countries_tags":["en:france"],"categories_tags":["en:beverages","en:tea-based-beverages","en:iced-teas","en:sweetened-beverages"]}}
            """,
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
