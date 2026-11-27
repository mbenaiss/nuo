// The app's IngredientRisk lives in ScanAPI.swift, which needs the whole network client; the shared card parser only
// reads its raw values.
enum IngredientRisk: String {
    case high, moderate, low, none
}
