import SwiftUI

enum ProductPhase: Equatable {
    case loading
    case loaded(FoodProduct)
    case failed(ProductLookupError)
}

/// Main-actor mirror of loaded products so a card re-rendered in a lazy list never flashes its skeleton.
@MainActor
enum ProductMemo {
    private static var products: [String: FoodProduct] = [:]

    static func phase(_ barcode: String) -> ProductPhase {
        products[barcode].map(ProductPhase.loaded) ?? .loading
    }

    static func load(_ barcode: String) async -> ProductPhase {
        if let product = products[barcode] { return .loaded(product) }
        do {
            let product = try await OpenFoodFactsClient.shared.product(barcode)
            products[barcode] = product
            return .loaded(product)
        } catch let error as ProductLookupError {
            return .failed(error)
        } catch {
            return .failed(.network)
        }
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 96
    var lineWidth: CGFloat = 10
    var showsScale = true
    @State private var progress: Double = 0

    var body: some View {
        let verdict = Verdict(score: score)
        ZStack {
            Circle().stroke(verdict.color.opacity(0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(verdict.color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: -2) {
                Text("\(score)")
                    .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.ink)
                if showsScale {
                    Text("/100")
                        .font(.system(size: size * 0.13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.text3)
                }
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.spring(response: 0.9, dampingFraction: 0.85).delay(0.05)) { progress = max(0.02, Double(score) / 100) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Estimated health score \(score) out of 100, \(verdict.label)")
    }
}

enum ScoreColors {
    static func nutriScore(_ grade: String) -> Color {
        switch grade {
        case "a": Color(hex: 0x038141)
        case "b": Color(hex: 0x85BB2F)
        case "c": Color(hex: 0xFECB02)
        case "d": Color(hex: 0xEE8100)
        default: Color(hex: 0xE63E11)
        }
    }

    static func nova(_ group: Int) -> Color {
        switch group {
        case 1: Color(hex: 0x00AA00)
        case 2: Color(hex: 0xFFCC00)
        case 3: Color(hex: 0xFF6600)
        default: Color(hex: 0xFF0000)
        }
    }

    static func greenScore(_ grade: String) -> Color {
        switch grade {
        case "a-plus": Color(hex: 0x0A7A3E)
        case "a": Color(hex: 0x1E8F4E)
        case "b": Color(hex: 0x60AC0E)
        case "c": Color(hex: 0xEEAE0E)
        case "d": Color(hex: 0xFF6F1E)
        case "e": Color(hex: 0xDF1F1F)
        default: Color(hex: 0xB71C1C)
        }
    }

    static func novaLabel(_ group: Int) -> String {
        switch group {
        case 1: String(localized: "Unprocessed or minimally processed")
        case 2: String(localized: "Culinary ingredient")
        case 3: String(localized: "Processed")
        default: String(localized: "Ultra-processed")
        }
    }

    static func greenLabel(_ grade: String) -> String {
        switch grade {
        case "a-plus": "A+"
        default: grade.uppercased()
        }
    }
}

/// Official-looking Nutri-Score strip: the five letters with the product's grade raised.
struct NutriScoreStrip: View {
    let grade: String
    var compact = false

    var body: some View {
        let cell: CGFloat = compact ? 15 : 22
        HStack(spacing: 0) {
            ForEach(["a", "b", "c", "d", "e"], id: \.self) { letter in
                let active = letter == grade
                Text(letter.uppercased())
                    .font(.system(size: active ? cell * 0.78 : cell * 0.56, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(active ? 1 : 0.75))
                    .frame(width: active ? cell * 1.35 : cell, height: active ? cell * 1.5 : cell)
                    .background(ScoreColors.nutriScore(letter).opacity(active ? 1 : 0.55), in: RoundedRectangle(cornerRadius: active ? cell * 0.38 : 0, style: .continuous))
                    .overlay {
                        if active {
                            RoundedRectangle(cornerRadius: cell * 0.38, style: .continuous).strokeBorder(.white, lineWidth: compact ? 1.5 : 2)
                        }
                    }
                    .zIndex(active ? 1 : 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cell * 0.3, style: .continuous).inset(by: -cell * 0.3))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Nutri-Score \(grade.uppercased())")
    }
}

struct ScoreLetterBadge: View {
    let text: String
    let color: Color
    var size: CGFloat = 30

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(minWidth: size, minHeight: size)
            .background(color, in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

/// Coloured four-zone gauge with a marker at the product's value.
struct NutrientGauge: View {
    let item: NutrientAssessment

    var body: some View {
        let levels: [QualityLevel] = item.kind.isPositive ? [.bad, .poor, .good, .excellent] : [.excellent, .good, .poor, .bad]
        let maxValue = item.gaugeMax
        let edges = [0] + item.thresholds + [maxValue]
        VStack(spacing: 2) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        ForEach(0..<4, id: \.self) { index in
                            Capsule()
                                .fill(levels[index].color.opacity(index == displayIndex ? 1 : 0.32))
                                .frame(width: max(2, width * (edges[index + 1] - edges[index]) / maxValue - 2), height: 8)
                        }
                    }
                    Circle()
                        .fill(Color.card)
                        .frame(width: 13, height: 13)
                        .overlay(Circle().strokeBorder(item.level.color, lineWidth: 3.5))
                        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                        .offset(x: min(width - 13, max(0, width * min(item.value, maxValue) / maxValue - 6.5)))
                }
                .frame(height: 13)
            }
            .frame(height: 13)
            GeometryReader { proxy in
                ForEach(Array(item.thresholds.enumerated()), id: \.offset) { _, threshold in
                    Text(NutrientFormat.grams(threshold))
                        .font(.system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(Color.text3)
                        .fixedSize()
                        .position(x: proxy.size.width * threshold / maxValue, y: 5)
                }
            }
            .frame(height: 10)
        }
        .accessibilityHidden(true)
    }

    private var displayIndex: Int {
        item.thresholds.firstIndex { item.value < $0 } ?? 3
    }
}

struct ProductPhoto: View {
    let url: String?
    var size: CGFloat = 88

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.white)
            if let url {
                RemoteImage(url: url, contentMode: .fit)
                    .padding(size * 0.06)
            } else {
                Image(systemName: "takeoutbag.and.cup.and.straw.fill")
                    .font(.system(size: size * 0.36))
                    .foregroundStyle(Color(hex: 0xA3A1A8))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.line, lineWidth: 1))
    }
}

/// Shimmering placeholder block for loading states.
struct SkeletonBlock: View {
    var width: CGFloat?
    var height: CGFloat
    var radius: CGFloat = 6
    @State private var phase = false

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.chip)
            .frame(width: width, height: height)
            .opacity(phase ? 0.55 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: phase)
            .onAppear { phase = true }
    }
}
