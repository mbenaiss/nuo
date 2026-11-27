import SwiftUI

/// Compact Yuka-style card for `::product`; tapping it opens the full sheet.
struct ProductCard: View {
    let payload: ProductPayload
    @State private var phase: ProductPhase
    @State private var showsSheet = false
    @Environment(\.sendCardPrompt) private var sendPrompt
    @Environment(\.cardBotName) private var botName

    init(payload: ProductPayload) {
        self.payload = payload
        _phase = State(initialValue: ProductMemo.phase(payload.barcode))
    }

    var body: some View {
        Group {
            switch phase {
            case .loading:
                skeleton
            case let .loaded(product):
                Button {
                    Haptics.tap()
                    showsSheet = true
                } label: {
                    loaded(product, analysis: ProductAnalysis(product))
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Opens the product details")
            case let .failed(error):
                failed(error)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .task(id: payload.barcode) {
            guard case .loading = phase else { return }
            let result = await ProductMemo.load(payload.barcode)
            withAnimation(.smooth(duration: 0.3)) { phase = result }
        }
        .sheet(isPresented: $showsSheet) {
            ProductSheetView(barcode: payload.barcode, initialPortion: payload.portion, botName: botName) { prompt in
                sendPrompt?.send(prompt)
            }
        }
    }

    private func loaded(_ product: FoodProduct, analysis: ProductAnalysis) -> some View {
        let grams = payload.portion ?? product.servingGrams ?? 100
        let macros = PortionMacros(product, grams: grams)
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .center, spacing: Spacing.sm) {
                ProductPhoto(url: product.imageURL, size: 64)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(product.name)
                        .font(.headline)
                        .foregroundStyle(Color.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([product.brand, product.quantity, product.origin?.primary?.label].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline)
                        .foregroundStyle(Color.text2)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if let grade = product.nutriscoreGrade {
                            miniBadge("Nutri-Score", ScoreLetterBadge(text: grade.uppercased(), color: ScoreColors.nutriScore(grade), size: 18))
                        }
                        if let nova = product.novaGroup {
                            miniBadge("NOVA", ScoreLetterBadge(text: "\(nova)", color: ScoreColors.nova(nova), size: 18))
                        }
                    }
                    .padding(.top, Spacing.xxs / 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(spacing: Spacing.xxs) {
                    ScoreRing(score: analysis.score.total, size: 58, lineWidth: 6, showsScale: false)
                    Text(analysis.score.verdict.label)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(analysis.score.verdict.color)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    Text("For \(NutrientFormat.grams(grams)) \(product.unit)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.text2)
                    Spacer()
                    HStack(spacing: 3) {
                        Text("View details")
                        Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentInk)
                }
                HStack(spacing: Spacing.xs) {
                    tile(String(localized: "Calories"), macros.kcal.map { "\(Int($0.rounded()))" }, unit: "kcal", level: level(.energy, analysis))
                    tile(String(localized: "Sugars"), macros.sugars.map { NutrientFormat.grams($0) }, unit: "g", level: level(.sugars, analysis))
                    tile(String(localized: "Protein"), macros.proteins.map { NutrientFormat.grams($0) }, unit: "g", level: level(.proteins, analysis))
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func level(_ kind: NutrientAssessment.Kind, _ analysis: ProductAnalysis) -> QualityLevel? {
        analysis.nutrients.first { $0.kind == kind }?.level
    }

    private func miniBadge(_ title: String, _ badge: some View) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Color.text2)
            badge
        }
        .padding(.leading, 8)
        .padding(.trailing, 3)
        .padding(.vertical, 3)
        .background(Color.chip, in: Capsule())
    }

    private func tile(_ label: String, _ value: String?, unit: String, level: QualityLevel?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(level?.color ?? Color.text3).frame(width: 6, height: 6)
                Text(label).font(.caption2).foregroundStyle(Color.text2).lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–").font(.headline.monospacedDigit()).foregroundStyle(Color.ink)
                Text(unit).font(.caption2.weight(.medium)).foregroundStyle(Color.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: CardMetrics.tileRadius, style: .continuous))
    }

    private var skeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                SkeletonBlock(width: 64, height: 64, radius: 15)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 150, height: 14)
                    SkeletonBlock(width: 90, height: 11)
                    SkeletonBlock(width: 120, height: 18, radius: 9)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SkeletonBlock(width: 58, height: 58, radius: 29)
            }
            HStack(spacing: Spacing.xs) {
                ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 46, radius: CardMetrics.tileRadius) }
            }
        }
        .accessibilityLabel("Loading product")
    }

    private func failed(_ error: ProductLookupError) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: error == .notFound ? "barcode.viewfinder" : "wifi.exclamationmark")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.text2)
                .frame(width: 48, height: 48)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            VStack(alignment: .leading, spacing: Spacing.xxs / 2) {
                Text(error == .notFound ? String(localized: "Product not found") : String(localized: "Details unavailable"))
                    .font(.headline).foregroundStyle(Color.ink)
                Text(error == .notFound ? String(localized: "Code \(payload.barcode) not found in Open Food Facts.") : String(localized: "Open Food Facts isn't responding."))
                    .font(.subheadline).foregroundStyle(Color.text2)
            }
            Spacer(minLength: 0)
            if error == .network {
                Button {
                    phase = .loading
                    Task {
                        let result = await ProductMemo.load(payload.barcode)
                        withAnimation(.smooth) { phase = result }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.subheadline.weight(.bold)).foregroundStyle(Color.ink)
                        .frame(width: 34, height: 34).background(Color.chip, in: Circle())
                }
                .accessibilityLabel("Try again")
            }
        }
    }
}
