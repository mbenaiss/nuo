import SwiftUI

/// Full product sheet (scores, nutrients, additives, portion) opened from a scan or a `::product` card.
struct ProductSheetView: View {
    let barcode: String
    var initialPortion: Double?
    var botName: String?

    private var saveLabel: String {
        botName.map { String(localized: "Save to \($0)") } ?? String(localized: "Save to the bot")
    }

    private var askLabel: String {
        botName.map { String(localized: "Ask \($0)") } ?? String(localized: "Ask the bot")
    }
    /// Scan flow only: hands the raw barcode to the bot instead of logging.
    var onAsk: (() -> Void)?
    let onSend: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var phase: ProductPhase
    @State private var grams: Double = 100
    @State private var preset: PortionPreset = .hundred
    @State private var ingredientsExpanded = false

    init(barcode: String, initialPortion: Double? = nil, botName: String? = nil, onAsk: (() -> Void)? = nil, onSend: @escaping (String) -> Void) {
        self.barcode = barcode
        self.initialPortion = initialPortion
        self.botName = botName
        self.onAsk = onAsk
        self.onSend = onSend
        let phase = ProductMemo.phase(barcode)
        _phase = State(initialValue: phase)
        if case let .loaded(product) = phase {
            let start = Self.startPortion(product, initialPortion)
            _grams = State(initialValue: start.grams)
            _preset = State(initialValue: start.preset)
        }
    }

    enum PortionPreset: Hashable {
        case serving, g25, g50, hundred, custom
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .loading:
                    loading
                case let .loaded(product):
                    content(product, analysis: ProductAnalysis(product))
                case let .failed(error):
                    failure(error)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.canvas)
            .navigationTitle("Product Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .tint(Color.ink)
                        .accessibilityLabel("Close")
                }
            }
        }
        .task(id: barcode) {
            guard case .loading = phase else { return }
            let result = await ProductMemo.load(barcode)
            if case let .loaded(product) = result {
                let start = Self.startPortion(product, initialPortion)
                grams = start.grams
                preset = start.preset
            }
            withAnimation(.smooth(duration: 0.3)) { phase = result }
        }
    }

    private static func startPortion(_ product: FoodProduct, _ initial: Double?) -> (grams: Double, preset: PortionPreset) {
        if let initial, initial > 0 {
            if initial == product.servingGrams { return (initial, .serving) }
            switch initial {
            case 25: return (25, .g25)
            case 50: return (50, .g50)
            case 100: return (100, .hundred)
            default: return (initial, .custom)
            }
        }
        if let serving = product.servingGrams, serving > 0 { return (serving, .serving) }
        return (100, .hundred)
    }

    // MARK: - Content

    private func content(_ product: FoodProduct, analysis: ProductAnalysis) -> some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header(product)
                scoreCard(analysis)
                badges(product)
                if !analysis.defects.isEmpty {
                    nutrientSection(title: String(localized: "Negatives"), symbol: "hand.thumbsdown.fill", tint: QualityLevel.bad.color, items: analysis.defects, product: product)
                        .id("details")
                }
                if !analysis.qualities.isEmpty {
                    nutrientSection(title: String(localized: "Positives"), symbol: "hand.thumbsup.fill", tint: QualityLevel.excellent.color, items: analysis.qualities, product: product)
                        .id(analysis.defects.isEmpty ? "details" : "qualities")
                }
                additivesSection(analysis.additives)
                if !analysis.allergens.isEmpty { allergensSection(analysis.allergens) }
                if let ingredients = product.ingredients { ingredientsSection(ingredients) }
                portionSection(product).id("portion")
                Text("Data from Open Food Facts (ODbL). Health score estimated by Nuo from nutrition (60%), additives (30%) and the organic label (10%).")
                    .font(.caption2)
                    .foregroundStyle(Color.text3)
                    .padding(.horizontal, 4)
                    .padding(.top, 2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(product) }
        .task {
            guard let section = DemoDirector.productSection else { return }
            try? await Task.sleep(for: .milliseconds(900))
            proxy.scrollTo(section, anchor: .top)
        }
        }
    }

    private func header(_ product: FoodProduct) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ProductPhoto(url: product.imageURL, size: 92)
            VStack(alignment: .leading, spacing: 4) {
                Text(product.name)
                    .font(.title3.bold())
                    .foregroundStyle(Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if let brand = product.brand {
                    Text(brand).font(.subheadline.weight(.medium)).foregroundStyle(Color.text2)
                }
                if let origin = product.origin { originLines(origin) }
                HStack(spacing: 6) {
                    if let quantity = product.quantity { Badge(text: quantity) }
                    if product.isOrganic { Badge(text: String(localized: "Organic"), dot: QualityLevel.excellent.color) }
                    Text(product.barcode)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.text3)
                        .lineLimit(1)
                }
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func originLines(_ origin: ProductOrigin) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if !origin.manufacturing.isEmpty {
                originLine(String(localized: "Made in"), origin.manufacturing)
            } else if let packer = origin.packaging {
                originLine(String(localized: "Packed in"), [packer])
            }
            if !origin.ingredients.isEmpty { originLine(String(localized: "Ingredients"), origin.ingredients) }
            if !origin.isKnown { originLine(String(localized: "Origin not specified · sold in"), origin.soldIn) }
        }
    }

    private func originLine(_ title: String, _ places: [ProductOrigin.Place]) -> some View {
        (Text("\(title) ").foregroundStyle(Color.text3) + Text(places.map(\.label).joined(separator: ", ")).foregroundStyle(Color.text2))
            .font(.caption.weight(.medium))
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func scoreCard(_ analysis: ProductAnalysis) -> some View {
        let score = analysis.score
        return HStack(spacing: 18) {
            ScoreRing(score: score.total, size: 104, lineWidth: 11)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(score.verdict.label)
                        .font(.title2.bold())
                        .foregroundStyle(score.verdict.color)
                    Text("Estimated health score")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.text2)
                }
                VStack(spacing: 5) {
                    breakdown(String(localized: "Nutrition"), value: score.nutrition, weight: "60 %")
                    breakdown(String(localized: "Additives"), value: score.additives, weight: "30 %")
                    breakdown(String(localized: "Organic"), value: score.organic ? 100 : 0, weight: "10 %")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .card(padding: 16)
    }

    private func breakdown(_ label: String, value: Int, weight: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.text2)
                .frame(width: 58, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.chip)
                    Capsule()
                        .fill(Verdict(score: value).color)
                        .frame(width: value == 0 ? 0 : max(5, proxy.size.width * Double(value) / 100))
                }
            }
            .frame(height: 5)
            Text(weight)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Color.text3)
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func badges(_ product: FoodProduct) -> some View {
        HStack(spacing: 10) {
            badgeTile(title: "Nutri-Score", caption: product.nutriscoreGrade.map { String(localized: "Grade \($0.uppercased())") } ?? String(localized: "Not calculated")) {
                if let grade = product.nutriscoreGrade {
                    NutriScoreStrip(grade: grade, compact: true)
                } else {
                    ScoreLetterBadge(text: "?", color: Color.text3, size: 26)
                }
            }
            badgeTile(title: "NOVA", caption: product.novaGroup.map(ScoreColors.novaLabel) ?? String(localized: "Unknown")) {
                if let nova = product.novaGroup {
                    ScoreLetterBadge(text: "\(nova)", color: ScoreColors.nova(nova), size: 26)
                } else {
                    ScoreLetterBadge(text: "?", color: Color.text3, size: 26)
                }
            }
            badgeTile(title: "Green-Score", caption: product.greenScoreGrade.map { String(localized: "Impact \(ScoreColors.greenLabel($0))") } ?? String(localized: "Unknown")) {
                if let grade = product.greenScoreGrade {
                    ScoreLetterBadge(text: ScoreColors.greenLabel(grade), color: ScoreColors.greenScore(grade), size: 26)
                } else {
                    ScoreLetterBadge(text: "?", color: Color.text3, size: 26)
                }
            }
        }
    }

    private func badgeTile(title: String, caption: String, @ViewBuilder badge: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(Color.text2)
            badge().frame(height: 32, alignment: .leading)
            Text(caption)
                .font(.caption2.weight(.medium))
                .foregroundStyle(Color.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card(padding: 12, radius: Radius.md)
    }

    private func sectionTitle(_ title: String, symbol: String, tint: Color, trailing: String? = nil) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.subheadline.weight(.bold)).foregroundStyle(tint)
            Text(title).font(.headline).foregroundStyle(Color.ink)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption.weight(.medium)).foregroundStyle(Color.text3)
            }
        }
    }

    private func nutrientSection(title: String, symbol: String, tint: Color, items: [NutrientAssessment], product: FoodProduct) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(title, symbol: symbol, tint: tint, trailing: String(localized: "per 100 \(product.unit)"))
            VStack(spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Color.line).padding(.leading, 50) }
                    nutrientRow(item)
                }
            }
        }
        .card(padding: 16)
    }

    private func nutrientRow(_ item: NutrientAssessment) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.level.color)
                .frame(width: 38, height: 38)
                .background(item.level.color.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.kind.title).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                        Text(item.label).font(.caption).foregroundStyle(Color.text2)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Text(NutrientFormat.value(item.value, kind: item.kind))
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(Color.ink)
                        Circle().fill(item.level.color).frame(width: 9, height: 9)
                    }
                }
                NutrientGauge(item: item)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func additivesSection(_ additives: [Additive]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "Additives"), symbol: "flask.fill", tint: additives.map(\.risk).max()?.level.color ?? QualityLevel.excellent.color,
                         trailing: additives.isEmpty ? nil : "\(additives.count)")
            if additives.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(QualityLevel.excellent.color)
                    Text("No additives").font(.subheadline.weight(.medium)).foregroundStyle(Color.ink)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(additives.enumerated()), id: \.element.id) { index, additive in
                        if index > 0 { Divider().overlay(Color.line).padding(.leading, 22) }
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(additive.risk.level.color).frame(width: 10, height: 10).padding(.top, 5)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("\(additive.code) · \(additive.name)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.ink)
                                    Spacer()
                                    Text(additive.risk.label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(additive.risk.level.color)
                                }
                                Text(additive.note).font(.caption).foregroundStyle(Color.text2)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .card(padding: 16)
    }

    private func allergensSection(_ allergens: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle(String(localized: "Allergens"), symbol: "allergens.fill", tint: Color(hex: 0xF29D38))
            FlowChips(items: allergens)
        }
        .card(padding: 16)
    }

    private func ingredientsSection(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy) { ingredientsExpanded.toggle() }
            } label: {
                HStack {
                    sectionTitle(String(localized: "Ingredients"), symbol: "list.bullet", tint: Color.text2)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.text3)
                        .rotationEffect(.degrees(ingredientsExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.text2)
                .lineLimit(ingredientsExpanded ? nil : 2)
                .lineSpacing(2)
                .textSelection(.enabled)
        }
        .card(padding: 16)
    }

    private func portionSection(_ product: FoodProduct) -> some View {
        let macros = PortionMacros(product, grams: grams)
        return VStack(alignment: .leading, spacing: 14) {
            sectionTitle(String(localized: "Portion"), symbol: "scalemass.fill", tint: Color.accent)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if let serving = product.servingGrams, serving > 0 {
                        presetChip(String(localized: "Portion · \(NutrientFormat.grams(serving)) \(product.unit)"), .serving, grams: serving)
                    }
                    presetChip("25 \(product.unit)", .g25, grams: 25)
                    presetChip("50 \(product.unit)", .g50, grams: 50)
                    presetChip("100 \(product.unit)", .hundred, grams: 100)
                }
            }
            .scrollClipDisabled()
            HStack(spacing: 12) {
                Text("Amount").font(.subheadline.weight(.medium)).foregroundStyle(Color.text2)
                Spacer()
                stepperButton("minus") { adjust(-5) }.disabled(grams <= 5)
                Text("\(NutrientFormat.grams(grams)) \(product.unit)")
                    .font(.title3.bold().monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText(value: grams))
                    .frame(minWidth: 76)
                stepperButton("plus") { adjust(5) }
            }
            HStack(spacing: 8) {
                macroTile(String(localized: "Calories"), macros.kcal.map { "\(Int($0.rounded()))" }, unit: "kcal", tint: Color.accent)
                macroTile(String(localized: "Protein"), macros.proteins.map { NutrientFormat.grams($0) }, unit: "g", tint: Color(hex: 0x3B82F6))
                macroTile(String(localized: "Carbs"), macros.carbs.map { NutrientFormat.grams($0) }, unit: "g", tint: Color(hex: 0xF5A524))
                macroTile(String(localized: "Fat"), macros.fat.map { NutrientFormat.grams($0) }, unit: "g", tint: Color(hex: 0xA855F7))
            }
        }
        .card(padding: 16)
    }

    private func presetChip(_ title: String, _ value: PortionPreset, grams target: Double) -> some View {
        let selected = preset == value
        return Button {
            Haptics.selection()
            withAnimation(.snappy) {
                preset = value
                grams = target
            }
        } label: {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(selected ? Color.onInk : Color.ink)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(selected ? Color.inkFill : Color.chip, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func stepperButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.selection()
            action()
        } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.ink)
                .frame(width: 38, height: 38)
                .background(Color.chip, in: Circle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(symbol == "plus" ? String(localized: "Add 5 grams") : String(localized: "Remove 5 grams"))
    }

    private func adjust(_ delta: Double) {
        withAnimation(.snappy) {
            let next = ((grams + delta) / 5).rounded() * 5
            grams = min(2000, max(5, next))
            preset = switch grams {
            case 25: .g25
            case 50: .g50
            case 100: .hundred
            default: .custom
            }
        }
    }

    private func macroTile(_ label: String, _ value: String?, unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(Color.text2).lineLimit(1).minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value ?? "–")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(Color.ink)
                    .contentTransition(.numericText())
                Text(unit).font(.caption2.weight(.medium)).foregroundStyle(Color.text2)
            }
            Capsule().fill(tint).frame(height: 3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func actionBar(_ product: FoodProduct) -> some View {
        let macros = PortionMacros(product, grams: grams)
        return VStack(spacing: 8) {
            Button {
                Haptics.send()
                onSend(macros.logPrompt(for: product))
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                    Text(saveLabel)
                    if let kcal = macros.kcal {
                        Text("· \(Int(kcal.rounded())) kcal").foregroundStyle(Color.onInk.opacity(0.6))
                    }
                }
            }
            .buttonStyle(InkButtonStyle())
            if let onAsk {
                Button {
                    dismiss()
                    onAsk()
                } label: {
                    Label(askLabel, systemImage: "bubble.left.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.canvas.ignoresSafeArea())
        .overlay(alignment: .top) { Divider().overlay(Color.line) }
    }

    // MARK: - States

    private var loading: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                SkeletonBlock(width: 92, height: 92, radius: 22)
                VStack(alignment: .leading, spacing: 8) {
                    SkeletonBlock(width: 180, height: 18)
                    SkeletonBlock(width: 100, height: 13)
                    SkeletonBlock(width: 70, height: 18, radius: 9)
                }
            }
            SkeletonBlock(height: 136, radius: Radius.lg)
            HStack(spacing: 10) {
                ForEach(0..<3, id: \.self) { _ in SkeletonBlock(height: 96, radius: Radius.md) }
            }
            SkeletonBlock(height: 220, radius: Radius.lg)
            Spacer()
        }
        .padding(16)
        .accessibilityLabel("Loading product")
    }

    private func failure(_ error: ProductLookupError) -> some View {
        VStack(spacing: 18) {
            Image(systemName: error == .notFound ? "barcode.viewfinder" : "wifi.exclamationmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Color.accent)
                .frame(width: 72, height: 72)
                .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            VStack(spacing: 6) {
                Text(error == .notFound ? String(localized: "Product not found") : String(localized: "Open Food Facts isn't responding"))
                    .font(.title3.bold()).foregroundStyle(Color.ink)
                Text(error == .notFound
                     ? String(localized: "Code \(barcode) isn't in Open Food Facts. The bot can still help you.")
                     : String(localized: "Check your connection and try again."))
                    .font(.subheadline).foregroundStyle(Color.text2).multilineTextAlignment(.center)
            }
            if error == .network {
                Button("Try again") {
                    phase = .loading
                    Task {
                        let result = await ProductMemo.load(barcode)
                        withAnimation(.smooth) { phase = result }
                    }
                }
                .buttonStyle(InkButtonStyle(prominent: onAsk == nil))
            }
            if let onAsk {
                Button(askLabel) {
                    dismiss()
                    onAsk()
                }
                .buttonStyle(InkButtonStyle())
            }
        }
        .padding(24)
        .frame(maxHeight: .infinity, alignment: .top)
        .padding(.top, 40)
    }
}

private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.accentSoft, in: Capsule())
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrange(width: bounds.width, subviews: subviews)
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
