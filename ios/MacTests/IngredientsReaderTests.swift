import Testing

struct IngredientsReaderTests {
    @Test func keepsTheListAfterItsHeading() {
        let back = "Crème mains Amande 50 ml Fabriqué en Suisse INGREDIENTS: AQUA, PRUNUS AMYGDALUS DULCIS OIL, GLYCERIN, PARFUM, LIMONENE"
        #expect(IngredientsReader.list(in: back) == "AQUA, PRUNUS AMYGDALUS DULCIS OIL, GLYCERIN, PARFUM, LIMONENE")
        #expect(IngredientsReader.list(in: "Ingrédients : Aqua, Glycerin") == "Aqua, Glycerin")
    }

    @Test func keepsEverythingWithoutAHeading() {
        #expect(IngredientsReader.list(in: "Aqua, Sodium Laureth Sulfate,\nParfum") == "Aqua, Sodium Laureth Sulfate, Parfum")
    }
}
