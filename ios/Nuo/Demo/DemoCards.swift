import Foundation

/// Scripted answers whose point is the card: a run and a strength session, a logged meal, a scanned drink, a parcel and the house.
/// English shows °F like the demo weather card; the French catalog has the °C version.
enum DemoCards {
    static var session: String {
        String(localized: "demo.cards.session", defaultValue: """
        Strong session: all **6 × 800 m** done, 4 s faster than planned.
        ::workout {"sport":"run","title":"Morning intervals","date":"This morning","time":"7:12 AM","duration":52,"distance":9.6,"pace":"4:31 /km","calories":690,"hr":{"avg":148,"max":179},"zones":[6,14,9,15,8],"laps":[{"time":"3:39","pace":"4:34 /km","hr":165},{"time":"3:37","pace":"4:31 /km","hr":168},{"time":"3:36","pace":"4:30 /km","hr":170},{"time":"3:37","pace":"4:31 /km","hr":172},{"time":"3:35","pace":"4:29 /km","hr":176},{"time":"3:34","pace":"4:28 /km","hr":179}],"note":"Your heart rate climbed on the last two reps: keep the full 2 min recovery next time."}
        """)
    }

    static var strength: String {
        String(localized: "demo.cards.strength", defaultValue: """
        Upper-body session logged: **+2.5 kg on the bench press** since last week.
        ::workout {"sport":"strength","title":"Upper body","date":"Today","time":"6:30 PM","duration":64,"calories":410,"hr":{"avg":118,"max":154},"exercises":[{"name":"Bench press","sets":[{"reps":8,"weight":70},{"reps":8,"weight":72.5},{"reps":6,"weight":72.5},{"reps":6,"weight":72.5}]},{"name":"Pull-ups","sets":[10,9,8],"note":"Bodyweight"},{"name":"Overhead press","sets":3,"reps":10,"weight":40},{"name":"Plank","sets":["60 s","60 s","45 s"]}],"note":"Next time: 72.5 kg on all four bench press sets."}
        """)
    }

    static var meal: String {
        String(localized: "demo.cards.meal", defaultValue: """
        Logged: **salmon poke bowl** for lunch. Good protein after this morning's intervals.
        ::meal {"name":"Salmon poke bowl","meal":"Lunch","time":"12:40 PM","calories":640,"protein":38,"carbs":72,"fat":21,"fiber":8,"items":[{"name":"Sushi rice","portion":"150 g","calories":195},{"name":"Raw salmon","portion":"100 g","calories":208},{"name":"Edamame","portion":"50 g","calories":61},{"name":"Avocado","portion":"½","calories":120},{"name":"Mango, cucumber, sesame","portion":"80 g","calories":56}],"goal":{"calories":2450,"protein":165,"carbs":280,"fat":75},"day":{"calories":1840,"protein":132,"carbs":190,"fat":58},"note":"610 kcal and 33 g of protein left for today."}
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
        ::home {"title":"Home","summary":"Everyone's out","updated":"6:05 PM","alerts":[{"text":"Bathroom window open","detail":"Open for 40 min while the radiator heats. I can turn it off until the window is closed.","level":"warning","kind":"window"}],"rooms":[{"name":"Living room","temperature":70.5,"humidity":44,"co2":620},{"name":"Bedroom","temperature":66.6,"humidity":48,"co2":540},{"name":"Kitchen","temperature":71.8,"humidity":51,"co2":1080},{"name":"Bathroom","temperature":63.1,"target":68,"humidity":72,"heating":true}],"devices":[{"name":"Front door","type":"lock","state":"Locked"},{"name":"Bathroom radiator","type":"heater","state":"Heating"},{"name":"Living room lights","type":"light","state":"Off"},{"name":"Bedroom blinds","type":"blind","state":"Closed"},{"name":"Washing machine","type":"washer","state":"Running","room":"Kitchen"}],"energy":{"today":9.4,"now":1.2,"cost":"$2.10","note":"0.7 kWh under your daily average"}}
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
