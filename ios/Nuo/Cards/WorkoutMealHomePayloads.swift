import Foundation

/// A figure of a card: a bare number the card formats and follows with `unit`, or a text the bot wrote in the
/// user's language ("4:31 /km"), shown as is.
struct CardQuantity: Hashable {
    var text: String?
    /// The bare number, or the one the text starts with (for bars and thresholds).
    var number: Double?
    var unit: String?

    init(text: String?, number: Double?, unit: String?) {
        self.text = text
        self.number = number
        self.unit = unit
    }

    /// `9.6`, `"9.6"` and `"9,6"` are numbers and get `unit`; any other text is kept as written.
    init?(_ value: Any?, unit: String?) {
        if let number = value as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
            self.init(text: nil, number: number.doubleValue, unit: unit)
            return
        }
        guard let raw = value as? String else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let number = Double(text.replacingOccurrences(of: ",", with: ".")), number.isFinite {
            self.init(text: nil, number: number, unit: unit)
        } else {
            self.init(text: text, number: Self.leadingNumber(text), unit: nil)
        }
    }

    /// "1,840 kcal" → 1840, "9,6 km" → 9.6, "38 g" → 38: a comma before exactly three digits groups thousands.
    static func leadingNumber(_ text: String) -> Double? {
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        var digits = ""
        for character in text.trimmingCharacters(in: .whitespaces) {
            if character.isASCII, character.isNumber || character == "." || character == "," || (character == "-" && digits.isEmpty) {
                digits.append(character)
            } else if spaces.contains(character), !digits.isEmpty {
                continue
            } else {
                break
            }
        }
        let groups = digits.split(separator: ",", omittingEmptySubsequences: false)
        if groups.count > 1, groups.dropFirst().allSatisfy({ $0.count == 3 && !$0.contains(".") }) {
            digits = groups.joined()
        } else {
            digits = digits.replacingOccurrences(of: ",", with: ".")
        }
        return Double(digits).flatMap { $0.isFinite ? $0 : nil }
    }
}

// MARK: - ::workout

struct WorkoutZone: Hashable {
    var label: String
    var minutes: Double?
    var percent: Double?
    /// The zone's time as the bot wrote it.
    var detail: String?

    /// Share of the bar.
    var weight: Double { max(0, minutes ?? percent ?? 0) }
}

struct WorkoutLap: Hashable {
    var label: String
    var distance: String?
    var time: String?
    var pace: String?
    var heartRate: String?
}

struct WorkoutSet: Hashable {
    var reps: Int?
    var weight: CardQuantity?
    /// A set told in words or time ("60 s", "500 m"), when it has neither reps nor weight.
    var text: String?
}

struct WorkoutExercise: Hashable {
    var name: String
    var sets: [WorkoutSet]
    var note: String?
}

/// `::workout`: a finished or ongoing session.
struct WorkoutPayload: Hashable {
    var sport: String?
    var title: String?
    var symbol: String?
    var date: String?
    var time: String?
    var status: String?
    var live = false
    var duration: CardQuantity?
    var distance: CardQuantity?
    var pace: CardQuantity?
    var speed: CardQuantity?
    var calories: CardQuantity?
    var averageHeartRate: CardQuantity?
    var maxHeartRate: CardQuantity?
    var elevation: CardQuantity?
    var effort: CardQuantity?
    var zones: [WorkoutZone] = []
    var laps: [WorkoutLap] = []
    var exercises: [WorkoutExercise] = []
    var note: String?

    /// SF Symbol of the sport, from English or French words.
    var sportSymbol: String {
        if let symbol { return symbol }
        let sport = (sport ?? title ?? "").lowercased()
        let table: [(words: [String], symbol: String)] = [
            (["trail", "hike", "hiking", "rando"], "figure.hiking"),
            (["run", "jog", "course", "footing"], "figure.run"),
            (["walk", "marche"], "figure.walk"),
            (["ride", "cycl", "bike", "vélo", "velo"], "figure.outdoor.cycle"),
            (["swim", "natation", "nage"], "figure.pool.swim"),
            (["row", "aviron", "rameur"], "figure.rower"),
            (["yoga"], "figure.yoga"),
            (["hiit", "interval", "fractionn"], "figure.highintensity.intervaltraining"),
            (["strength", "weight", "gym", "muscu", "lift", "force"], "dumbbell.fill"),
            (["climb", "escalade"], "figure.climbing"),
            (["ski"], "figure.skiing.downhill"),
            (["tennis"], "figure.tennis"),
            (["football", "soccer", "foot"], "figure.soccer"),
            (["box"], "figure.boxing"),
            (["pilates", "stretch", "mobilit", "étirement"], "figure.pilates"),
        ]
        return table.first { $0.words.contains(where: sport.contains) }?.symbol ?? "figure.mixed.cardio"
    }
}

// MARK: - ::meal

struct MealItem: Hashable {
    var name: String
    var portion: String?
    var calories: CardQuantity?
}

/// Calories and grams of macros, for a daily goal or what was eaten so far today.
struct MealTotals: Hashable {
    var calories: Double?
    var protein: Double?
    var carbs: Double?
    var fat: Double?
    var fiber: Double?

    var isEmpty: Bool { [calories, protein, carbs, fat, fiber].allSatisfy { $0 == nil } }
}

/// `::meal`: a meal logged or analysed.
struct MealPayload: Hashable {
    var name: String?
    /// Breakfast, lunch… in the user's language.
    var moment: String?
    var time: String?
    var calories: CardQuantity?
    var protein: CardQuantity?
    var carbs: CardQuantity?
    var fat: CardQuantity?
    var fiber: CardQuantity?
    var items: [MealItem] = []
    var goal: MealTotals?
    /// Eaten today, this meal included.
    var day: MealTotals?
    var note: String?
}

// MARK: - ::home

struct HomeRoom: Hashable {
    var name: String
    var temperature: CardQuantity?
    var target: CardQuantity?
    var humidity: CardQuantity?
    var co2: CardQuantity?
    var heating: Bool?
}

struct HomeDevice: Hashable {
    var name: String
    /// light, heater, blind, plug, lock…
    var kind: String?
    var symbol: String?
    var room: String?
    /// As the bot wrote it; nil when the state was a plain on or off.
    var state: String?
    var isOn: Bool?
}

struct HomeAlert: Hashable {
    var text: String
    var detail: String?
    /// info, warning or critical.
    var level: String
    var kind: String?
    var symbol: String?
}

struct HomeEnergy: Hashable {
    var today: CardQuantity?
    var now: CardQuantity?
    var cost: String?
    var note: String?
}

/// `::home`: the state of the house.
struct HomePayload: Hashable {
    var title: String?
    var summary: String?
    var updated: String?
    var rooms: [HomeRoom] = []
    var devices: [HomeDevice] = []
    var alerts: [HomeAlert] = []
    var energy: HomeEnergy?
}

// MARK: - Parsing

extension ResponseBlockParser.Fields {
    func quantity(_ unit: String?, _ keys: String...) -> CardQuantity? {
        for key in keys {
            if let quantity = CardQuantity(json[key], unit: unit) { return quantity }
        }
        return nil
    }

    func number(_ keys: String...) -> Double? {
        for key in keys {
            if let number = CardQuantity(json[key], unit: nil)?.number { return number }
        }
        return nil
    }
}

extension ResponseBlockParser {
    private typealias F = ResponseBlockParser.Fields

    private static func objects(_ value: Any?) -> [[String: Any]] {
        if let array = value as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        if let object = value as? [String: Any] { return [object] }
        return []
    }

    /// An array, or an object keyed by name (`{"Living room": {...}}`) whose keys become `nameKey`.
    private static func namedObjects(_ value: Any?, nameKey: String) -> [Any] {
        if let array = value as? [Any] { return array }
        guard let object = value as? [String: Any], object.values.allSatisfy({ $0 is [String: Any] }) else { return [] }
        return object.keys.sorted().compactMap { key in
            guard var entry = object[key] as? [String: Any] else { return nil }
            if entry[nameKey] == nil { entry[nameKey] = key }
            return entry
        }
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return nil
    }

    // MARK: Workout

    static func workout(_ json: [String: Any]) -> WorkoutPayload? {
        let f = F(json: json)
        let sport = f.string("sport", "activity", "discipline")
        let title = f.string("title", "name")
        guard sport != nil || title != nil else { return nil }
        let hr = f.object("hr") ?? f.object("heartRate") ?? f.object("heart_rate")
        return WorkoutPayload(
            sport: sport, title: title, symbol: f.string("symbol", "icon"),
            date: f.string("date", "day"), time: f.string("time", "start", "startTime", "start_time"),
            status: f.string("status", "state"), live: f.bool("live", "inProgress", "in_progress", "ongoing") ?? false,
            duration: f.quantity("min", "duration", "elapsed", "movingTime", "moving_time"),
            distance: f.quantity("km", "distance"),
            pace: f.quantity("/km", "pace", "avgPace"),
            speed: f.quantity("km/h", "speed", "avgSpeed"),
            calories: f.quantity("kcal", "calories", "kcal", "activeCalories", "energy"),
            averageHeartRate: hr?.quantity("bpm", "avg", "average", "mean")
                ?? f.quantity("bpm", "avgHr", "avg_hr", "averageHeartRate", "avgHeartRate", "heartRate", "hr"),
            maxHeartRate: hr?.quantity("bpm", "max", "peak") ?? f.quantity("bpm", "maxHr", "max_hr", "maxHeartRate"),
            elevation: f.quantity("m", "elevation", "ascent", "elevationGain", "elevation_gain", "climb"),
            effort: f.quantity(nil, "effort", "strain", "load", "trainingLoad", "rpe"),
            zones: zones(json["zones"] ?? json["hrZones"] ?? json["heartRateZones"] ?? hr?.json["zones"]),
            laps: laps(json["laps"] ?? json["splits"] ?? json["intervals"]),
            exercises: exercises(json["exercises"] ?? json["movements"]),
            note: f.string("note", "summary", "comment", "verdict"))
    }

    private static func zoneLabel(_ value: Any?, index: Int) -> String {
        if let number = value as? NSNumber { return "Z\(number.intValue)" }
        guard let label = text(value) else { return "Z\(index + 1)" }
        return label.allSatisfy(\.isNumber) ? "Z\(label)" : label
    }

    /// `[6, 9, 14, 15, 8]` (minutes from zone 1), `[{"zone": 2, "minutes": 12}]` or `{"z1": 6, "z2": 9}`.
    private static func zones(_ value: Any?) -> [WorkoutZone] {
        if let object = value as? [String: Any] {
            return object.keys.sorted().enumerated().compactMap { index, key in
                guard let minutes = CardQuantity(object[key], unit: nil)?.number else { return nil }
                return WorkoutZone(label: zoneLabel(key.uppercased(), index: index), minutes: minutes)
            }
        }
        guard let array = value as? [Any] else { return [] }
        return array.enumerated().compactMap { index, entry -> WorkoutZone? in
            if let entry = entry as? [String: Any] {
                let e = F(json: entry)
                let label = zoneLabel(entry["zone"] ?? entry["label"] ?? entry["name"], index: index)
                let detail = e.string("time", "duration", "value")
                var minutes = e.number("minutes", "min")
                if minutes == nil, let seconds = e.number("seconds", "sec", "s") { minutes = seconds / 60 }
                if minutes == nil, let detail, let leading = CardQuantity.leadingNumber(detail), !detail.contains("%") { minutes = leading }
                let percent = e.number("percent", "pct", "share") ?? detail.flatMap { $0.contains("%") ? CardQuantity.leadingNumber($0) : nil }
                guard minutes != nil || percent != nil || detail != nil else { return nil }
                return WorkoutZone(label: label, minutes: minutes, percent: percent, detail: detail)
            }
            guard let minutes = CardQuantity(entry, unit: nil)?.number else { return nil }
            return WorkoutZone(label: "Z\(index + 1)", minutes: minutes)
        }
    }

    private static func laps(_ value: Any?) -> [WorkoutLap] {
        guard let array = value as? [Any] else { return [] }
        return array.enumerated().compactMap { index, entry -> WorkoutLap? in
            guard let entry = entry as? [String: Any] else {
                return text(entry).map { WorkoutLap(label: "\(index + 1)", time: $0) }
            }
            let e = F(json: entry)
            let lap = WorkoutLap(
                label: e.string("label", "name", "lap", "split", "km") ?? "\(index + 1)",
                distance: e.string("distance"), time: e.string("time", "duration"),
                pace: e.string("pace", "speed"), heartRate: e.string("hr", "heartRate", "avgHr", "bpm"))
            guard lap.distance != nil || lap.time != nil || lap.pace != nil || lap.heartRate != nil else { return nil }
            return lap
        }
    }

    private static func workoutSet(_ value: Any?, reps: Int? = nil, weight: CardQuantity? = nil) -> WorkoutSet? {
        if let object = value as? [String: Any] {
            let e = F(json: object)
            let set = WorkoutSet(
                reps: e.int("reps", "rep", "count"), weight: e.quantity("kg", "weight", "load", "kg"),
                text: e.string("text", "label", "duration", "time", "distance"))
            return set.reps == nil && set.weight == nil && set.text == nil ? nil : set
        }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return WorkoutSet(reps: number.intValue, weight: weight)
        }
        return text(value).map { WorkoutSet(text: $0) }
    }

    private static func exercises(_ value: Any?) -> [WorkoutExercise] {
        guard let array = value as? [Any] else { return [] }
        return array.compactMap { entry -> WorkoutExercise? in
            guard let entry = entry as? [String: Any] else {
                return text(entry).map { WorkoutExercise(name: $0, sets: []) }
            }
            let e = F(json: entry)
            guard let name = e.string("name", "exercise", "title", "movement") else { return nil }
            let reps = e.int("reps", "rep")
            let weight = e.quantity("kg", "weight", "load", "kg")
            var sets: [WorkoutSet] = []
            if let list = entry["sets"] as? [Any] {
                sets = list.compactMap { workoutSet($0, reps: reps, weight: weight) }
            } else if let count = e.int("sets", "series"), count > 0, reps != nil || weight != nil {
                sets = Array(repeating: WorkoutSet(reps: reps, weight: weight), count: min(count, 20))
            } else if reps != nil || weight != nil {
                sets = [WorkoutSet(reps: reps, weight: weight)]
            }
            return WorkoutExercise(name: name, sets: sets, note: e.string("note", "comment"))
        }
    }

    // MARK: Meal

    private static func totals(_ value: Any?) -> MealTotals? {
        if let calories = CardQuantity(value, unit: nil)?.number { return MealTotals(calories: calories) }
        guard let object = value as? [String: Any] else { return nil }
        let e = F(json: object)
        let totals = MealTotals(
            calories: e.number("calories", "kcal", "energy"), protein: e.number("protein", "proteins"),
            carbs: e.number("carbs", "carbohydrates"), fat: e.number("fat", "fats", "lipids"), fiber: e.number("fiber", "fibre", "fibers"))
        return totals.isEmpty ? nil : totals
    }

    static func meal(_ json: [String: Any]) -> MealPayload? {
        let f = F(json: json)
        let macros = f.object("macros") ?? f.object("totals") ?? f.object("nutrition") ?? f
        func macro(_ keys: String...) -> CardQuantity? {
            for key in keys {
                if let value = CardQuantity(json[key], unit: "g") ?? CardQuantity(macros.json[key], unit: "g") { return value }
            }
            return nil
        }
        let items = (json["items"] ?? json["foods"] ?? json["ingredients"]).map { value -> [MealItem] in
            ((value as? [Any]) ?? []).compactMap { entry in
                guard let entry = entry as? [String: Any] else { return text(entry).map { MealItem(name: $0) } }
                let e = F(json: entry)
                guard let name = e.string("name", "food", "title", "label") else { return nil }
                return MealItem(
                    name: name, portion: e.string("portion", "quantity", "amount", "serving") ?? e.quantity("g", "grams").map(Self.portionText),
                    calories: e.quantity("kcal", "calories", "kcal", "energy"))
            }
        } ?? []
        let name = f.string("name", "title", "dish")
        let moment = f.string("meal", "moment", "slot")
        guard name != nil || moment != nil || !items.isEmpty else { return nil }
        return MealPayload(
            name: name, moment: moment, time: f.string("time", "at", "date"),
            calories: f.quantity("kcal", "calories", "kcal", "energy") ?? macros.quantity("kcal", "calories", "kcal", "energy"),
            protein: macro("protein", "proteins"), carbs: macro("carbs", "carbohydrates"),
            fat: macro("fat", "fats", "lipids"), fiber: macro("fiber", "fibre", "fibers"),
            items: items,
            goal: totals(json["goal"] ?? json["goals"] ?? json["target"] ?? json["targets"]),
            day: totals(json["day"] ?? json["today"] ?? json["dayTotal"] ?? json["consumed"]),
            note: f.string("note", "verdict", "comment", "summary"))
    }

    /// Grams given as a number: "150 g".
    private static func portionText(_ grams: CardQuantity) -> String {
        guard grams.text == nil, let number = grams.number else { return grams.text ?? "" }
        let rounded = number.rounded() == number ? String(Int(number)) : String(number)
        return "\(rounded) g"
    }

    // MARK: Home

    static func home(_ json: [String: Any]) -> HomePayload? {
        let f = F(json: json)
        let rooms = namedObjects(json["rooms"] ?? json["areas"], nameKey: "name").compactMap { entry -> HomeRoom? in
            guard let entry = entry as? [String: Any] else { return text(entry).map { HomeRoom(name: $0) } }
            let e = F(json: entry)
            guard let name = e.string("name", "room", "area", "title") else { return nil }
            return HomeRoom(
                name: name, temperature: e.quantity("°", "temperature", "temp", "current"),
                target: e.quantity("°", "target", "setpoint", "targetTemperature"),
                humidity: e.quantity("%", "humidity", "hum"), co2: e.quantity("ppm", "co2", "CO2", "co2_ppm"),
                heating: e.bool("heating", "isHeating"))
        }
        let devices = namedObjects(json["devices"] ?? json["entities"] ?? json["appliances"], nameKey: "name").compactMap { entry -> HomeDevice? in
            guard let entry = entry as? [String: Any] else { return nil }
            let e = F(json: entry)
            guard let name = e.string("name", "title", "label") else { return nil }
            let rawState = entry["state"] ?? entry["status"] ?? entry["value"]
            let plain = (rawState as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? $0.boolValue : nil }
            let state = plain == nil ? text(rawState) : nil
            return HomeDevice(
                name: name, kind: e.string("type", "kind", "domain", "class"), symbol: e.string("symbol", "icon"),
                room: e.string("room", "area"), state: state, isOn: e.bool("on", "isOn", "active") ?? plain ?? deviceIsOn(state))
        }
        let alerts = (((json["alerts"] ?? json["warnings"] ?? json["issues"]) as? [Any]) ?? []).compactMap { entry -> HomeAlert? in
            guard let entry = entry as? [String: Any] else { return text(entry).map { HomeAlert(text: $0, level: "warning") } }
            let e = F(json: entry)
            guard let text = e.string("text", "title", "message", "name", "label") else { return nil }
            return HomeAlert(
                text: text, detail: e.string("detail", "description", "since"),
                level: (e.string("level", "severity", "style") ?? "warning").lowercased(),
                kind: e.string("kind", "type", "category")?.lowercased(), symbol: e.string("symbol", "icon"))
        }
        let energy = homeEnergy(json["energy"] ?? json["power"])
        guard !rooms.isEmpty || !devices.isEmpty || !alerts.isEmpty || energy != nil else { return nil }
        return HomePayload(
            title: f.string("title", "name"), summary: f.string("summary", "status", "text"), updated: f.string("updated", "at", "time"),
            rooms: rooms, devices: devices, alerts: alerts, energy: energy)
    }

    private static func homeEnergy(_ value: Any?) -> HomeEnergy? {
        if let today = CardQuantity(value, unit: "kWh") { return HomeEnergy(today: today) }
        guard let object = value as? [String: Any] else { return nil }
        let e = F(json: object)
        let energy = HomeEnergy(
            today: e.quantity("kWh", "today", "day", "consumption", "total", "kwh"), now: e.quantity("kW", "now", "power", "current", "live"),
            cost: e.string("cost", "price"), note: e.string("note", "trend", "comparison", "detail"))
        return energy.today == nil && energy.now == nil && energy.cost == nil ? nil : energy
    }

    /// Whether a device is on, from the word or number its state holds; nil when it says neither.
    static func deviceIsOn(_ state: String?) -> Bool? {
        guard let state = state?.lowercased().trimmingCharacters(in: .whitespaces), !state.isEmpty else { return nil }
        if state.first?.isNumber == true, let level = CardQuantity.leadingNumber(state) { return level > 0 }
        let on: Set<String> = [
            "on", "open", "opened", "unlocked", "heating", "cooling", "playing", "running", "active",
            "allumé", "allumée", "allumés", "allumées", "ouvert", "ouverte", "ouverts", "ouvertes", "en marche",
            "déverrouillé", "déverrouillée", "en chauffe",
        ]
        let off: Set<String> = [
            "off", "closed", "locked", "idle", "standby", "paused", "stopped", "inactive",
            "éteint", "éteinte", "éteints", "éteintes", "fermé", "fermée", "fermés", "fermées",
            "verrouillé", "verrouillée", "arrêté", "en veille",
        ]
        if on.contains(state) { return true }
        if off.contains(state) { return false }
        return nil
    }
}
