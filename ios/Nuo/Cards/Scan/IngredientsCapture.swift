import SwiftUI

/// Shows what was read so the user fixes a misread word before the analysis.
struct IngredientsReviewSheet: View {
    let barcode: String
    @State var name: String
    @State var text: String
    let onAnalysed: (CosmeticProduct) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scanAPI) private var api
    @State private var sending = false
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Product") {
                    TextField("Product name (optional)", text: $name)
                }
                Section {
                    TextEditor(text: $text).frame(minHeight: 180).font(.callout)
                } header: {
                    Text("Ingredients read from the photo")
                } footer: {
                    Text("Fix any misread word if needed. The list is kept: the next scan of this code will use it.")
                }
                if let failure {
                    Text(failure).font(.footnote).foregroundStyle(Color.bad)
                }
            }
            .navigationTitle("Ingredient List")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if sending { ProgressView() } else {
                        Button("Analyze", action: analyse).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func analyse() {
        guard let api else { failure = String(localized: "Nuo isn't connected to the gateway."); return }
        sending = true
        failure = nil
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        Task {
            defer { sending = false }
            do {
                let result = try await api.rememberIngredients(code: barcode, ingredients: text, name: trimmedName.isEmpty ? nil : trimmedName)
                if let product = result.cosmetic {
                    onAnalysed(product)
                    dismiss()
                }
            } catch {
                failure = String(localized: "Couldn't analyze: \(error.localizedDescription)")
            }
        }
    }
}
