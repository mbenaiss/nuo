import Foundation
import Vision

/// Reads a photographed INCI list on the device: no base knows every cosmetic, every cosmetic sold in Europe prints its list.
enum IngredientsReader {
    static func text(from image: Data) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["fr-FR", "en-US"]
            // INCI names are Latin and chemical words: correcting them towards French or English breaks them.
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(data: image).perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return list(in: lines.joined(separator: " "))
        }.value
    }

    /// The list after its heading (« Ingredients: », « Ingrédients : », « INCI: »), the whole text when there is none.
    static func list(in text: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let heading = flat.range(of: #"(?i)(ingr[ée]dients?|inci)\s*[:：]"#, options: .regularExpression) else {
            return flat.trimmingCharacters(in: .whitespaces)
        }
        return flat[heading.upperBound...].trimmingCharacters(in: .whitespaces)
    }
}
