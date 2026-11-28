import Foundation
import Testing

struct WorkoutMealHomeCardTests {
    private func only(_ text: String) -> ResponseBlock? {
        let blocks = ResponseBlockParser.parse(text)
        return blocks.count == 1 ? blocks[0] : nil
    }

    // MARK: Workout

    @Test func aRunReadsEveryFigure() throws {
        let line = #"::workout {"sport":"run","title":"Fractionné du matin","date":"2026-11-28","time":"07:12","duration":52,"distance":9.6,"pace":"4:31 /km","calories":690,"hr":{"avg":148,"max":179},"elevation":84,"effort":14.2,"zones":[6,14,9,15,8],"laps":[{"time":"3:39","pace":"4:34 /km","hr":165},{"label":"2","distance":"800 m","time":"3:34"}],"note":"Garde les 2 min de récupération."}"#
        guard case let .workout(run)? = only(line) else { Issue.record("not a workout card"); return }
        #expect(run.sport == "run")
        #expect(run.title == "Fractionné du matin")
        #expect(run.date == "2026-11-28" && run.time == "07:12")
        #expect(run.duration == CardQuantity(text: nil, number: 52, unit: "min"))
        #expect(run.distance == CardQuantity(text: nil, number: 9.6, unit: "km"))
        #expect(run.pace == CardQuantity(text: "4:31 /km", number: 4, unit: nil))
        #expect(run.calories == CardQuantity(text: nil, number: 690, unit: "kcal"))
        #expect(run.averageHeartRate?.number == 148 && run.maxHeartRate?.number == 179 && run.maxHeartRate?.unit == "bpm")
        #expect(run.elevation == CardQuantity(text: nil, number: 84, unit: "m"))
        #expect(run.effort == CardQuantity(text: nil, number: 14.2, unit: nil))
        #expect(run.zones.map(\.label) == ["Z1", "Z2", "Z3", "Z4", "Z5"])
        #expect(run.zones.map(\.minutes) == [6, 14, 9, 15, 8])
        #expect(run.laps == [
            WorkoutLap(label: "1", time: "3:39", pace: "4:34 /km", heartRate: "165"),
            WorkoutLap(label: "2", distance: "800 m", time: "3:34"),
        ])
        #expect(run.note == "Garde les 2 min de récupération.")
        #expect(run.sportSymbol == "figure.run")
        #expect(!run.live)
    }

    @Test func aStrengthSessionListsItsSets() throws {
        let line = #"::workout {"sport":"strength","title":"Haut du corps","live":true,"exercises":[{"name":"Développé couché","sets":[{"reps":8,"weight":70},{"reps":6,"weight":"72,5 kg"}]},{"name":"Tractions","sets":[10,9]},{"name":"Développé militaire","sets":3,"reps":10,"weight":40},{"name":"Gainage","sets":["60 s","45 s"]},"Étirements",{"sets":[8]}]}"#
        guard case let .workout(gym)? = only(line) else { Issue.record("not a workout card"); return }
        #expect(gym.live)
        #expect(gym.sportSymbol == "dumbbell.fill")
        #expect(gym.exercises == [
            WorkoutExercise(name: "Développé couché", sets: [
                WorkoutSet(reps: 8, weight: CardQuantity(text: nil, number: 70, unit: "kg")),
                WorkoutSet(reps: 6, weight: CardQuantity(text: "72,5 kg", number: 72.5, unit: nil)),
            ]),
            WorkoutExercise(name: "Tractions", sets: [WorkoutSet(reps: 10), WorkoutSet(reps: 9)]),
            WorkoutExercise(name: "Développé militaire", sets: Array(repeating: WorkoutSet(reps: 10, weight: CardQuantity(text: nil, number: 40, unit: "kg")), count: 3)),
            WorkoutExercise(name: "Gainage", sets: [WorkoutSet(text: "60 s"), WorkoutSet(text: "45 s")]),
            WorkoutExercise(name: "Étirements", sets: []),
        ])
    }

    @Test func aWorkoutNeedsOnlyItsSportOrTitle() throws {
        #expect(only(#"::workout {"sport":"swim"}"#) == .workout(WorkoutPayload(sport: "swim")))
        #expect(only(#"::workout {"title":"Yoga du soir"}"#) == .workout(WorkoutPayload(title: "Yoga du soir")))
        let noName = #"::workout {"duration":45,"calories":320}"#
        #expect(ResponseBlockParser.parse(noName) == [.paragraph(noName)])
    }

    @Test func aWorkoutToleratesTextsAndOddTypes() throws {
        let line = #"::session {"title":"Sortie vélo","duration":"1 h 32","distance":"42,5","speed":31.4,"calories":"1 120 kcal","heartRate":"132 bpm","maxHr":true,"zones":{"z2":40,"z1":12,"z3":"25"},"laps":["12:10","11:58",{"lap":3},false],"exercises":"aucun"}"#
        guard case let .workout(ride)? = only(line) else { Issue.record("not a workout card"); return }
        #expect(ride.duration == CardQuantity(text: "1 h 32", number: 1, unit: nil))
        #expect(ride.distance == CardQuantity(text: nil, number: 42.5, unit: "km"))
        #expect(ride.speed == CardQuantity(text: nil, number: 31.4, unit: "km/h"))
        #expect(ride.calories == CardQuantity(text: "1 120 kcal", number: 1120, unit: nil))
        #expect(ride.averageHeartRate == CardQuantity(text: "132 bpm", number: 132, unit: nil))
        #expect(ride.maxHeartRate == nil)
        #expect(ride.zones.map(\.label) == ["Z1", "Z2", "Z3"])
        #expect(ride.zones.map(\.minutes) == [12, 40, 25])
        #expect(ride.laps == [WorkoutLap(label: "1", time: "12:10"), WorkoutLap(label: "2", time: "11:58")])
        #expect(ride.exercises.isEmpty)
        #expect(ride.sportSymbol == "figure.outdoor.cycle")
    }

    @Test func zonesGivenAsObjectsKeepTheirLabelsAndTimes() throws {
        let line = #"::training {"sport":"run","zones":[{"zone":2,"minutes":20},{"label":"Seuil","percent":35},{"zone":"5","time":"4 min"},{"zone":4}]}"#
        guard case let .workout(run)? = only(line) else { Issue.record("not a workout card"); return }
        #expect(run.zones == [
            WorkoutZone(label: "Z2", minutes: 20),
            WorkoutZone(label: "Seuil", percent: 35),
            WorkoutZone(label: "Z5", minutes: 4, detail: "4 min"),
        ])
    }

    // MARK: Meal

    @Test func aMealReadsItsMacrosFoodsAndGoal() throws {
        let line = #"::meal {"name":"Poke bowl au saumon","meal":"Déjeuner","time":"12 h 40","calories":640,"protein":38,"carbs":"72 g","fat":21,"fiber":8,"items":[{"name":"Riz à sushi","portion":"150 g","calories":195},{"name":"Saumon cru","grams":100,"calories":208},"Sésame"],"goal":{"calories":2450,"protein":165,"carbs":280,"fat":75},"day":{"calories":"1 840","protein":132},"note":"Il te reste 33 g de protéines."}"#
        guard case let .meal(lunch)? = only(line) else { Issue.record("not a meal card"); return }
        #expect(lunch.name == "Poke bowl au saumon" && lunch.moment == "Déjeuner" && lunch.time == "12 h 40")
        #expect(lunch.calories == CardQuantity(text: nil, number: 640, unit: "kcal"))
        #expect(lunch.protein == CardQuantity(text: nil, number: 38, unit: "g"))
        #expect(lunch.carbs == CardQuantity(text: "72 g", number: 72, unit: nil))
        #expect(lunch.fat?.number == 21 && lunch.fiber?.number == 8)
        #expect(lunch.items == [
            MealItem(name: "Riz à sushi", portion: "150 g", calories: CardQuantity(text: nil, number: 195, unit: "kcal")),
            MealItem(name: "Saumon cru", portion: "100 g", calories: CardQuantity(text: nil, number: 208, unit: "kcal")),
            MealItem(name: "Sésame"),
        ])
        #expect(lunch.goal == MealTotals(calories: 2450, protein: 165, carbs: 280, fat: 75))
        #expect(lunch.day == MealTotals(calories: 1840, protein: 132))
        #expect(lunch.note == "Il te reste 33 g de protéines.")
    }

    @Test func aMealNeedsANameAMomentOrFoods() throws {
        #expect(only(#"::meal {"meal":"Petit-déjeuner"}"#) == .meal(MealPayload(moment: "Petit-déjeuner")))
        #expect(only(#"::nutrition {"items":["Pomme","Yaourt nature"]}"#) == .meal(MealPayload(items: [MealItem(name: "Pomme"), MealItem(name: "Yaourt nature")])))
        let macrosOnly = #"::meal {"calories":420,"protein":30}"#
        #expect(ResponseBlockParser.parse(macrosOnly) == [.paragraph(macrosOnly)])
    }

    @Test func aMealReadsNestedMacrosAndACaloriesGoal() throws {
        let line = #"::meal {"name":"Omelette aux champignons","macros":{"calories":"380 kcal","protein":"24,5","carbs":6,"fat":28},"goal":2200,"day":"oui","items":{"name":"Œufs"}}"#
        guard case let .meal(dinner)? = only(line) else { Issue.record("not a meal card"); return }
        #expect(dinner.calories == CardQuantity(text: "380 kcal", number: 380, unit: nil))
        #expect(dinner.protein == CardQuantity(text: nil, number: 24.5, unit: "g"))
        #expect(dinner.carbs?.number == 6 && dinner.fat?.number == 28)
        #expect(dinner.goal == MealTotals(calories: 2200))
        #expect(dinner.day == nil)
        #expect(dinner.items.isEmpty)
    }

    // MARK: Home

    @Test func aHouseReadsRoomsDevicesAlertsAndEnergy() throws {
        let line = #"::home {"title":"Maison","summary":"Tout le monde est sorti","updated":"18 h 05","alerts":[{"text":"Fenêtre de la salle de bain ouverte","detail":"Depuis 40 min","level":"Warning","kind":"Window"},"Pile faible du détecteur de fumée"],"rooms":[{"name":"Salon","temperature":21.4,"humidity":"44","co2":620},{"name":"Salle de bain","temperature":"17,3 °C","target":20,"heating":true}],"devices":[{"name":"Porte d'entrée","type":"lock","state":"Verrouillée"},{"name":"Lampe du bureau","type":"light","state":true,"room":"Bureau"},{"name":"Volets du salon","type":"blind","state":"40 %"},{"name":"Lave-linge","state":"Essorage","on":true}],"energy":{"today":9.4,"now":"1,2 kW","cost":"1,95 €","note":"Sous ta moyenne"}}"#
        guard case let .home(house)? = only(line) else { Issue.record("not a home card"); return }
        #expect(house.title == "Maison" && house.summary == "Tout le monde est sorti" && house.updated == "18 h 05")
        #expect(house.alerts == [
            HomeAlert(text: "Fenêtre de la salle de bain ouverte", detail: "Depuis 40 min", level: "warning", kind: "window"),
            HomeAlert(text: "Pile faible du détecteur de fumée", level: "warning"),
        ])
        #expect(house.rooms == [
            HomeRoom(name: "Salon", temperature: CardQuantity(text: nil, number: 21.4, unit: "°"),
                     humidity: CardQuantity(text: nil, number: 44, unit: "%"), co2: CardQuantity(text: nil, number: 620, unit: "ppm")),
            HomeRoom(name: "Salle de bain", temperature: CardQuantity(text: "17,3 °C", number: 17.3, unit: nil),
                     target: CardQuantity(text: nil, number: 20, unit: "°"), heating: true),
        ])
        #expect(house.devices == [
            HomeDevice(name: "Porte d'entrée", kind: "lock", state: "Verrouillée", isOn: false),
            HomeDevice(name: "Lampe du bureau", kind: "light", room: "Bureau", state: nil, isOn: true),
            HomeDevice(name: "Volets du salon", kind: "blind", state: "40 %", isOn: true),
            HomeDevice(name: "Lave-linge", state: "Essorage", isOn: true),
        ])
        #expect(house.energy == HomeEnergy(
            today: CardQuantity(text: nil, number: 9.4, unit: "kWh"), now: CardQuantity(text: "1,2 kW", number: 1.2, unit: nil),
            cost: "1,95 €", note: "Sous ta moyenne"))
    }

    @Test func aHouseNeedsSomethingToShow() throws {
        #expect(only(#"::house {"energy":12.6}"#) == .home(HomePayload(energy: HomeEnergy(today: CardQuantity(text: nil, number: 12.6, unit: "kWh")))))
        let empty = #"::home {"title":"Maison","rooms":[],"devices":[{"state":"on"}],"energy":{}}"#
        #expect(ResponseBlockParser.parse(empty) == [.paragraph(empty)])
    }

    @Test func roomsKeyedByNameAreSortedAndNamed() throws {
        let line = #"::home {"rooms":{"Salon":{"temperature":21},"Chambre":{"temperature":19,"name":"Chambre parentale"}}}"#
        guard case let .home(house)? = only(line) else { Issue.record("not a home card"); return }
        #expect(house.rooms.map(\.name) == ["Chambre parentale", "Salon"])
        #expect(house.rooms.map { $0.temperature?.number } == [19, 21])
    }

    @Test func aDeviceStateSaysWhetherItIsOn() {
        #expect(ResponseBlockParser.deviceIsOn("On") == true)
        #expect(ResponseBlockParser.deviceIsOn("Allumées") == true)
        #expect(ResponseBlockParser.deviceIsOn("en chauffe") == true)
        #expect(ResponseBlockParser.deviceIsOn("off") == false)
        #expect(ResponseBlockParser.deviceIsOn("Fermés") == false)
        #expect(ResponseBlockParser.deviceIsOn("0 %") == false)
        #expect(ResponseBlockParser.deviceIsOn("65%") == true)
        #expect(ResponseBlockParser.deviceIsOn("Mode éco") == nil)
        #expect(ResponseBlockParser.deviceIsOn(nil) == nil)
    }

    // MARK: Shared

    @Test func brokenOrUnknownMarkersStayText() {
        let broken = #"::workout {"sport":"run","duration":52"#
        #expect(ResponseBlockParser.parse(broken) == [.paragraph(broken)])
        let unknown = #"::gym {"title":"Haut du corps"}"#
        #expect(ResponseBlockParser.parse(unknown) == [.paragraph(unknown)])
        let notAnObject = #"::meal ["Pomme"]"#
        #expect(ResponseBlockParser.parse(notAnObject) == [.paragraph(notAnObject)])
    }

    @Test func leadingNumbersReadGroupsAndDecimalCommas() {
        #expect(CardQuantity.leadingNumber("1,840 kcal") == 1840)
        #expect(CardQuantity.leadingNumber("1 840 kcal") == 1840)
        #expect(CardQuantity.leadingNumber("9,6 km") == 9.6)
        #expect(CardQuantity.leadingNumber("72.5 kg") == 72.5)
        #expect(CardQuantity.leadingNumber("-3 °C") == -3)
        #expect(CardQuantity.leadingNumber("environ 40") == nil)
    }

    @Test func theWatchShowsCompactCards() {
        let run = #"::workout {"sport":"run","title":"Footing","duration":"45 min","distance":8}"#
        #expect(MessageContent.blocks(run) == [.card(.compact(.init(kind: "WORKOUT", symbol: "figure.run", tint: .accent, title: "Footing", detail: "45 min · 8 km")))])
        let alert = #"::home {"alerts":["Fuite sous l'évier"],"energy":7}"#
        #expect(MessageContent.blocks(alert) == [.card(.compact(.init(kind: "HOME", symbol: "exclamationmark.triangle.fill", tint: .bad, title: "Fuite sous l'évier", detail: "7 kWh")))])
    }
}
