import SwiftUI
import UniformTypeIdentifiers

/// Compact card for `::cosmetic`: score and the riskiest ingredients; tapping opens the full analysis.
struct CosmeticCard: View {
    let payload: CosmeticPayload
    @State private var showsSheet = false

    var body: some View {
        Button {
            Haptics.tap()
            showsSheet = true
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(alignment: .center, spacing: Spacing.sm) {
                    ProductPhoto(url: payload.image, size: 64)
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        Text(payload.name).font(.headline).foregroundStyle(Color.ink).lineLimit(2).multilineTextAlignment(.leading)
                        Text([String(localized: "Cosmetic"), payload.brand].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.text2).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    CosmeticScore(score: payload.score, size: 58)
                }
                if payload.flagged.isEmpty {
                    Text(payload.score == nil ? String(localized: "Ingredients not provided") : String(localized: "No risky ingredient spotted"))
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.text2)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(payload.flagged.prefix(4).enumerated()), id: \.offset) { _, flag in
                            RiskRow(name: flag.name, risk: flag.risk, reason: nil)
                        }
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .sheet(isPresented: $showsSheet) { CosmeticSheetView(barcode: payload.barcode, fallback: payload) }
    }
}

struct CosmeticScore: View {
    let score: Int?
    var size: CGFloat

    var body: some View {
        if let score {
            VStack(spacing: Spacing.xxs) {
                ScoreRing(score: score, size: size, lineWidth: size / 10, showsScale: false)
                Text(Verdict(score: score).label).font(.caption.weight(.bold)).foregroundStyle(Verdict(score: score).color)
            }
        } else {
            Image(systemName: "questionmark.circle").font(.system(size: size * 0.5)).foregroundStyle(Color.text3)
        }
    }
}

struct RiskRow: View {
    let name: String
    let risk: IngredientRisk
    let reason: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Circle().fill(risk.color).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(name.capitalized).font(.subheadline).foregroundStyle(Color.ink)
                if let reason { Text(reason).font(.caption).foregroundStyle(Color.text2) }
            }
            Spacer(minLength: Spacing.xs)
            Text(risk.label).font(.caption2.weight(.semibold)).foregroundStyle(risk.color)
        }
    }
}

/// Full analysis of a cosmetic: score, every ingredient with its risk, read from `GET /api/scan/:code?kind=cosmetic`.
struct CosmeticSheetView: View {
    let barcode: String
    var fallback: CosmeticPayload?
    var onAsk: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scanAPI) private var api
    @Environment(\.openURL) private var openURL
    @State private var product: CosmeticProduct?
    @State private var failed = false
    /// The base did not answer (as opposed to not knowing the code): worth trying again later.
    @State private var unreachable = false
    @State private var capturing = false
    @State private var reading = false
    @State private var review: IngredientsDraft?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let product {
                        header(name: product.name, brand: product.brand, image: product.imageUrl, score: product.analysis.score)
                        facts(product)
                        if product.analysis.ingredients.isEmpty { photoButton(name: product.name) }
                        ingredients(product.analysis)
                        Text("\(Self.sourceLabel(product.source)) Score estimated by Nuo: the riskiest ingredient caps the score (high 25, moderate 50, low 75).")
                            .font(.caption2).foregroundStyle(Color.text3)
                    } else if let fallback {
                        header(name: fallback.name, brand: fallback.brand, image: fallback.image, score: fallback.score)
                        if failed {
                            Text(unreachable ? String(localized: "Open Beauty Facts isn't responding: detailed analysis unavailable for now.") : String(localized: "Detailed analysis unavailable."))
                                .font(.subheadline).foregroundStyle(Color.text2)
                        } else {
                            ProgressView().frame(maxWidth: .infinity)
                        }
                    } else if failed, unreachable {
                        ContentUnavailableView {
                            Label("Open Beauty Facts isn't responding", systemImage: "wifi.exclamationmark")
                        } description: {
                            Text("The cosmetics database is unavailable right now: code \(barcode) couldn't be checked.")
                        } actions: {
                            Button("Try again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                    } else if failed {
                        ContentUnavailableView("Cosmetic not found", systemImage: "drop", description: Text("Code \(barcode) not found in Open Beauty Facts, INCI API, UPCitemdb or Open Products Facts. Photograph the ingredient list on the back: Nuo analyzes it and remembers it for this code."))
                        photoButton(name: "")
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    }
                    if let onAsk {
                        Button("Ask the bot") { dismiss(); onAsk() }.buttonStyle(InkButtonStyle())
                    }
                }
                .padding(16)
            }
            .background(Color.canvas)
            .navigationTitle("Cosmetic")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }.tint(Color.ink).accessibilityLabel("Close")
                }
            }
        }
        .task(id: barcode) { await load() }
        .sheet(item: $review) { draft in
            IngredientsReviewSheet(barcode: barcode, name: draft.name, text: draft.text) { analysed in
                product = analysed
                failed = false
                unreachable = false
            }
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $capturing) {
            CameraPicker { data in read(data) }.ignoresSafeArea()
        }
        #else
        .fileImporter(isPresented: $capturing, allowedContentTypes: [.image]) { result in
            guard case let .success(url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            if let data = try? Data(contentsOf: url) { read(data) }
        }
        #endif
    }

    private static func sourceLabel(_ source: String?) -> String {
        switch source {
        case "inciapi": String(localized: "Data from INCI API.")
        case "openfoodfacts": String(localized: "Data from Open Food Facts (ODbL), where this cosmetic is wrongly listed among foods.")
        case "upcitemdb": String(localized: "Name found in UPCitemdb, without an ingredient list.")
        case "openproductsfacts": String(localized: "Name found in Open Products Facts (ODbL), without an ingredient list.")
        case "photo": String(localized: "Photographed ingredient list.")
        default: String(localized: "Data from Open Beauty Facts (ODbL).")
        }
    }

    private func photoButton(name: String) -> some View {
        Button {
            capturing = true
        } label: {
            HStack {
                if reading { ProgressView() } else { Image(systemName: "text.viewfinder") }
                Text(reading ? String(localized: "Reading the list…") : String(localized: "Photograph the ingredient list"))
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(reading)
        .onAppear { pendingName = name }
    }

    @State private var pendingName = ""

    private func read(_ image: Data) {
        reading = true
        Task {
            defer { reading = false }
            let text = (try? await IngredientsReader.text(from: image)) ?? ""
            review = IngredientsDraft(name: pendingName, text: text)
        }
    }

    private func load() async {
        guard product == nil else { return }
        guard let api else { failed = true; return }
        failed = false
        do {
            let result = try await api.scan(code: barcode, symbology: nil, kind: .cosmetic)
            product = result.cosmetic
            unreachable = result.cosmetic == nil && result.error != nil
            failed = product == nil
        } catch {
            unreachable = true
            failed = true
        }
    }

    private func header(name: String, brand: String?, image: String?, score: Int?) -> some View {
        HStack(spacing: Spacing.md) {
            ProductPhoto(url: image, size: 88)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(name).font(.title3.bold()).foregroundStyle(Color.ink)
                if let brand { Text(brand).font(.subheadline).foregroundStyle(Color.text2) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            CosmeticScore(score: score, size: 76)
        }
        .card()
    }

    private func facts(_ p: CosmeticProduct) -> some View {
        let items = [(String(localized: "Amount"), p.quantity), (String(localized: "After opening"), p.periodAfterOpening), (String(localized: "Labels"), p.labels.isEmpty ? nil : p.labels.joined(separator: ", "))]
            .compactMap { label, value in value.map { (label, $0) } }
        return Group {
            if !items.isEmpty || URL(string: p.url) != nil {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(items, id: \.0) { item in
                        HStack { Text(item.0).foregroundStyle(Color.text2); Spacer(); Text(item.1).foregroundStyle(Color.ink).multilineTextAlignment(.trailing) }
                            .font(.subheadline)
                    }
                    if let url = URL(string: p.url) {
                        Button("View on Open Beauty Facts") { openURL(url) }.font(.subheadline.weight(.semibold)).tint(Color.accentInk)
                    }
                }
                .card()
            }
        }
    }

    private func ingredients(_ a: CosmeticAnalysis) -> some View {
        let sorted = a.ingredients.enumerated().sorted { ($0.element.risk.rank, -$0.offset) > ($1.element.risk.rank, -$1.offset) }.map(\.element)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionTitle(text: String(localized: "Ingredients (\(a.ingredients.count))")) {
                Text("\(a.counts.high) high · \(a.counts.moderate) moderate · \(a.counts.low) low").font(.caption).foregroundStyle(Color.text2)
            }
            if sorted.isEmpty {
                Text("Ingredient list missing from Open Beauty Facts.").font(.subheadline).foregroundStyle(Color.text2)
            }
            ForEach(Array(sorted.enumerated()), id: \.offset) { _, ingredient in
                RiskRow(name: ingredient.name, risk: ingredient.risk, reason: ingredient.reason)
            }
        }
        .card()
    }
}

struct IngredientsDraft: Identifiable {
    let id = UUID()
    let name: String
    let text: String
}
