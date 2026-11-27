import Foundation

/// Scripted answers whose point is the card: a workout recap, a logged meal, a scanned drink, a parcel and the house.
/// English shows °F like the demo weather card; the French catalog has the °C version.
enum DemoCards {
    static var session: String {
        String(localized: "demo.cards.session", defaultValue: """
        Strong session: all **6 × 800 m** done at **4:31/km** on average, 4 s faster than planned. Your heart rate climbed on the last two reps, so keep the full 2 min recovery next time.
        ::metrics {"title":"This morning's intervals","symbol":"figure.run","items":[["Distance","9.6 km"],["Duration","52 min"],["Avg. pace","4:31 /km"],["Avg. heart rate","148 bpm"],["Strain","14.2"],["Calories","690 kcal"]]}
        ::chart {"title":"Heart rate","symbol":"heart.fill","type":"line","unit":"bpm","average":148,"points":[["0'",104],["5'",124],["10'",136],["15'",168],["20'",149],["25'",172],["30'",151],["35'",176],["40'",179],["45'",146],["50'",121]]}
        """)
    }

    static var meal: String {
        String(localized: "demo.cards.meal", defaultValue: """
        Logged: **salmon poke bowl** for lunch. Good protein after this morning's intervals.
        ::facts {"title":"Lunch · Salmon poke bowl","items":[["Calories","640 kcal"],["Protein","38 g"],["Carbs","72 g"],["Fat","21 g"],["Fiber","8 g"]]}
        ::metrics {"title":"Left for today","symbol":"fork.knife","items":[["Calories","610 kcal"],["Protein","33 g"],["Carbs","90 g"],["Fat","17 g"]]}
        """)
    }

    static func drink(_ barcode: String) -> String {
        String(localized: "It's **Orchard Peach Iced Tea**: 25 g of sugar in the can, about 6 sugar cubes.")
            + "\n::product {\"barcode\":\"\(barcode)\",\"portion_g\":\(DemoProducts.portion(barcode))}\n"
            + String(localized: "After this morning's run, sparkling water with lemon would do better. Should I log the can anyway?")
    }

    static var house: String {
        String(localized: "demo.cards.house", defaultValue: """
        All good at home, except one thing: the **bathroom window** has been open for 40 min with the heating on.
        ::metrics {"title":"Home right now","symbol":"house.fill","items":[["Living room","70.5 °F"],["Bedroom","66.6 °F"],["Kitchen","71.8 °F"],["Bathroom","63.1 °F"],["Front door","Locked"],["Power now","1.2 kW"]]}
        ::callout {"style":"warning","title":"Bathroom window open","text":"Open for 40 min while the radiator heats. I can turn the radiator off until it's closed."}
        ::chart {"title":"Energy this week","symbol":"bolt.fill","type":"bar","unit":"kWh","average":9,"points":[["Mon",8.2],["Tue",7.4],["Wed",9.1],["Thu",7.9],["Fri",8.6],["Sat",11.2],["Sun",10.4]]}
        """)
    }

    static func parcel(now: Date = Date()) -> String {
        func at(hoursAgo: Double) -> String { ISO8601Wire.format(now.addingTimeInterval(-hoursAgo * 3600)) }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let outForDelivery = String(localized: "Out for delivery with the driver")
        let card: [String: Any] = [
            "id": "pcl-demo-shoes", "number": "NLX48152026773", "label": String(localized: "Running shoes"),
            "carrier": "Northline Express", "status": "out_for_delivery", "statusLabel": String(localized: "Out for delivery"),
            "lastEvent": outForDelivery, "lastEventAt": at(hoursAgo: 1.5), "eta": day.string(from: now),
            "events": [
                ["label": outForDelivery, "at": at(hoursAgo: 1.5), "location": "Paris"],
                ["label": String(localized: "Arrived at the local depot"), "at": at(hoursAgo: 9), "location": "Gennevilliers"],
                ["label": String(localized: "In transit between hubs"), "at": at(hoursAgo: 26), "location": "Lyon"],
                ["label": String(localized: "Picked up by the carrier"), "at": at(hoursAgo: 44), "location": "Lyon"],
                ["label": String(localized: "Shipping label created"), "at": at(hoursAgo: 60)],
            ],
        ]
        let json = (try? JSONSerialization.data(withJSONObject: card, options: [.sortedKeys, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return String(localized: "Your **running shoes** are out for delivery. The driver should come by **between 2 and 4 pm**.")
            + "\n::parcel " + json
    }
}
