import Foundation

enum WeatherSymbols {
    /// The card guide uses short icon names ("sun", "cloud"…); SF Symbol names pass through.
    static func sfSymbol(_ name: String?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        if name.contains(".") { return name }
        switch name.lowercased() {
        case "sun", "clear", "sunny": return "sun.max.fill"
        case "cloud", "cloudy", "overcast": return "cloud.fill"
        case "partly", "partly-cloudy", "partlycloudy", "cloud-sun", "cloudsun": return "cloud.sun.fill"
        case "rain", "showers", "drizzle": return "cloud.rain.fill"
        case "storm", "thunder", "thunderstorm": return "cloud.bolt.rain.fill"
        case "snow": return "cloud.snow.fill"
        case "fog", "mist", "haze": return "cloud.fog.fill"
        case "wind", "windy": return "wind"
        case "moon", "night": return "moon.stars.fill"
        default: return symbol(for: name)
        }
    }

    static func symbol(for condition: String) -> String {
        let lower = condition.lowercased()
        if lower.contains("orage") || lower.contains("storm") { return "cloud.bolt.rain.fill" }
        if lower.contains("neige") || lower.contains("snow") { return "cloud.snow.fill" }
        if lower.contains("pluie") || lower.contains("averse") || lower.contains("rain") { return "cloud.rain.fill" }
        if lower.contains("brouillard") || lower.contains("brume") || lower.contains("fog") { return "cloud.fog.fill" }
        if lower.contains("soleil") || lower.contains("ensoleill") || lower.contains("dégagé") || lower.contains("clear") || lower.contains("sunny") { return "sun.max.fill" }
        if lower.contains("nuag") || lower.contains("couvert") || lower.contains("cloud") { return "cloud.fill" }
        return "cloud.sun.fill"
    }
}
