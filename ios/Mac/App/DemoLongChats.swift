#if DEBUG
import Foundation

/// Conversations holding messages several screens tall, which the scripted chat test (`-demoBench chat`) opens: a group
/// travel manifest pasted and returned as a 469-line CSV block, or a 469-paragraph trip journal.
enum DemoLongChats {
    enum Long {
        /// The manifest pasted, answered with the same lines as a code block.
        case manifest
        /// A short question answered with a day-by-day journal, one paragraph a day.
        case journal
    }

    struct Layout {
        let name: String
        let turns: Int
        let long: Set<Int>
        let kind: Long
    }

    /// The layouts that opened mid-answer or on an empty area before the transcript was cut into rows a screen tall.
    static let layouts = [
        Layout(name: "3 turns, manifests in turns 2 and 3", turns: 3, long: [1, 2], kind: .manifest),
        Layout(name: "3 turns, manifests in turns 1 and 2", turns: 3, long: [0, 1], kind: .manifest),
        Layout(name: "2 turns, journal in turn 2", turns: 2, long: [1], kind: .journal),
        Layout(name: "5 turns, manifests in turns 1, 3 and 5", turns: 5, long: [0, 2, 4], kind: .manifest),
    ]

    static let lineCount = 469

    static func messages(_ layout: Layout, conversationId: String, start: Date = Date().addingTimeInterval(-3_600)) -> [Message] {
        (0..<layout.turns).flatMap { turn -> [Message] in
            let date = start.addingTimeInterval(TimeInterval(turn * 120))
            let long = layout.long.contains(turn)
            let question: String
            let answer: String
            switch (long, layout.kind) {
            case (true, .manifest):
                question = "Vérifie le manifeste du groupe Martin pour le vol TO8285 et rends-le moi en CSV :\n" + manifest(turn: turn)
                answer = "Voici le manifeste vérifié, \(lineCount) passagers :\n\n```csv\n\(manifest(turn: turn))\n```\n\n"
                    + "Aucun doublon de siège ; les bagages en soute sont tous sous 23 kg."
            case (true, .journal):
                question = "Écris-moi le carnet de voyage complet du séjour, un paragraphe par jour."
                answer = "Voici le carnet, jour par jour :\n\n" + journal()
            case (false, _):
                question = "Que prévoit-on le jour \(turn + 1) à Paris ?"
                answer = "Jour \(turn + 1) : arrivée à Paris Orly par le TO8285 à 17:05, porte F32. Navette jusqu'à l'hôtel "
                    + "Rue de Rivoli, dîner réservé à 20:30 au nom de Martin.\n- Navette : 12 € par personne\n- Dîner : 38 € par personne"
            }
            return [
                Message(id: "\(conversationId)-q\(turn)", conversationId: conversationId, role: .user, text: question, createdAt: date),
                Message(
                    id: "\(conversationId)-a\(turn)", conversationId: conversationId, role: .assistant, text: answer,
                    steps: [ToolStep(toolCallId: "\(conversationId)-s\(turn)", title: "Read manifeste-TO8285.csv", kind: "read", status: .completed, durationMs: 300)],
                    durationMs: 6_000, stopReason: .endTurn, createdAt: date.addingTimeInterval(20)),
            ]
        }
    }

    private static let firstNames = ["Julie", "Karim", "Inès", "Thomas", "Leïla", "Hugo", "Sarah", "Youssef", "Camille", "Mehdi", "Emma", "Nour"]
    private static let lastNames = ["Martin", "Ben Salah", "Dubois", "Trabelsi", "Lefèvre", "Haddad", "Moreau", "Gharbi", "Laurent", "Mansouri"]
    private static let seatLetters = ["A", "B", "C", "D", "E", "F"]

    private static func manifest(turn: Int) -> String {
        (0..<lineCount).map { index in
            let name = "\(firstNames[index % firstNames.count]) \(lastNames[(index / firstNames.count + turn) % lastNames.count])"
            let seat = "\(index / seatLetters.count + 1)\(seatLetters[index % seatLetters.count])"
            let bag = 15 + (index * 7) % 9
            return "TO8285;2026-06-\(String(format: "%02d", 14 + turn));Rome-Fiumicino;Paris Orly;14:40;17:05;F32;\(seat);\(name);\(bag) kg"
        }
        .joined(separator: "\n")
    }

    private static let mornings = [
        "petit-déjeuner à l'hôtel puis métro jusqu'au Louvre, entrée réservée à 9:30",
        "marché d'Aligre à l'ouverture, puis balade le long du canal Saint-Martin",
        "croisière sur la Seine depuis le pont de l'Alma, départ à 10:15",
        "visite guidée de Montmartre, rendez-vous devant la station Abbesses",
    ]
    private static let afternoons = [
        "déjeuner rue Montorgueil et après-midi libre au Marais",
        "musée d'Orsay, billets coupe-file au nom de Martin",
        "jardin du Luxembourg puis librairies du Quartier latin",
        "shopping aux Galeries Lafayette et vue depuis la terrasse",
    ]

    private static func journal() -> String {
        (1...lineCount).map { day in
            "Jour \(day). Le matin, \(mornings[day % mornings.count]). L'après-midi, \(afternoons[(day / 2) % afternoons.count]). "
                + "Retour à l'hôtel vers 19:00 ; le soir, dîner près de la place des Vosges. Budget de la journée : \(60 + day % 40) € par personne."
        }
        .joined(separator: "\n\n")
    }
}
#endif
