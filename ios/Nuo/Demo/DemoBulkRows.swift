#if DEBUG
import Foundation

/// `-demo -demoRows 10000` adds a wide bank-transactions collection with that many rows, as many transfers, half as
/// many invoices and a tenth as many clients, to profile long collections; the values are deterministic so runs compare.
enum DemoBulkRows {
    static var count: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-demo"), let index = arguments.firstIndex(of: "-demoRows"), index + 1 < arguments.count else { return nil }
        return Int(arguments[index + 1])
    }

    static var transactions: DataCollection { DataCollection(id: "transactions", label: "Transactions", emoji: "🏦", count: 0, columns: [
        DataColumn(name: "libelle", label: String(localized: "demo.data.transactions.libelle", defaultValue: "Label"), type: .text, order: 0),
        DataColumn(name: "date", label: String(localized: "demo.data.transactions.date", defaultValue: "Date"), type: .datetime, order: 1),
        DataColumn(name: "montant", label: String(localized: "demo.data.transactions.montant", defaultValue: "Amount"), type: .money, order: 2),
        DataColumn(name: "sens", label: String(localized: "demo.data.transactions.sens", defaultValue: "Direction"), type: .select, options: [DataOption(value: "debit", label: String(localized: "demo.data.transactions.option.debit", defaultValue: "Debit"), color: "red"), DataOption(value: "credit", label: String(localized: "demo.data.transactions.option.credit", defaultValue: "Credit"), color: "green")], order: 3),
        DataColumn(name: "type", label: String(localized: "demo.data.transactions.type", defaultValue: "Type"), type: .select, options: ["carte", "virement", "prelevement", "frais"].map { DataOption(value: $0) }, order: 4),
        DataColumn(name: "statut", label: String(localized: "demo.data.transactions.statut", defaultValue: "Status"), type: .select, options: [DataOption(value: "pending", label: String(localized: "demo.data.transactions.option.pending", defaultValue: "Pending"), color: "yellow"), DataOption(value: "settled", label: String(localized: "demo.data.transactions.option.settled", defaultValue: "Settled"), color: "green"), DataOption(value: "declined", label: String(localized: "demo.data.transactions.option.declined", defaultValue: "Declined"), color: "red")], order: 5),
        DataColumn(name: "categorie", label: String(localized: "demo.data.transactions.categorie", defaultValue: "Category"), type: .select, options: ["restaurant", "transport", "logiciel", "materiel", "impots", "salaire", "client"].map { DataOption(value: $0) }, order: 6),
        DataColumn(name: "contrepartie", label: String(localized: "demo.data.transactions.contrepartie", defaultValue: "Counterparty"), type: .text, order: 7),
        DataColumn(name: "reference", label: String(localized: "demo.data.transactions.reference", defaultValue: "Reference"), type: .text, order: 8),
        DataColumn(name: "tva", label: String(localized: "demo.data.transactions.tva", defaultValue: "VAT"), type: .money, order: 9),
        DataColumn(name: "taux", label: String(localized: "demo.data.transactions.taux", defaultValue: "Rate"), type: .percent, order: 10),
        DataColumn(name: "carte", label: String(localized: "demo.data.transactions.carte", defaultValue: "Card"), type: .text, order: 11),
        DataColumn(name: "justificatif", label: String(localized: "demo.data.transactions.justificatif", defaultValue: "Receipt"), type: .bool, order: 12),
        DataColumn(name: "rapproche", label: String(localized: "demo.data.transactions.rapproche", defaultValue: "Reconciled"), type: .bool, order: 13),
        DataColumn(name: "facture_id", label: String(localized: "demo.data.transactions.facture_id", defaultValue: "Invoice"), type: .ref, ref: "factures", order: 14),
        DataColumn(name: "note", label: String(localized: "demo.data.transactions.note", defaultValue: "Note"), type: .longtext, order: 15),
        DataColumn(name: "solde", label: String(localized: "demo.data.transactions.solde", defaultValue: "Balance"), type: .money, computed: true, order: 16),
    ], titleColumn: "libelle", defaultSort: "date:desc") }

    static func add(_ count: Int, to rows: inout [String: [DataRow]], collections: [DataCollection], now: Date) {
        var random = Generator(seed: 42)
        let merchants = ["Carte Monoprix", "Carte SNCF Connect", "Prélèvement Free Mobile", "Carte Uber", "Virement Nordline Logistique",
                         "Carte Amazon", "Prélèvement EDF", "Carte Apple", "Virement Vélocité SAS", "Carte Deliveroo", "Prélèvement Alan",
                         "Carte Leroy Merlin", "Virement Urssaf", "Carte Station Total", "Prélèvement Banque Horizon"]
        let categories = ["client", "urssaf", "tva", "salaire", "abonnement"]
        let statuses = ["brouillon", "envoyee", "payee", "retard"]
        let cities = ["Paris", "Lyon", "Lille", "Nantes", "Bordeaux", "Marseille", "Toulouse"]

        func day(_ offset: Int) -> String {
            ValueFormat.dayString(now.addingTimeInterval(-Double(offset) * 86_400))
        }

        let clients = (0..<max(1, count / 10)).map { index in
            DataRow(id: "bulk-cli-\(index)", values: [
                "nom": .string("Client \(index) · \(cities[index % cities.count])"),
                "statut": .string(["actif", "prospect", "pause"][index % 3]),
                "contact": .string("Contact \(index)"),
                "ville": .string(cities[random.next(cities.count)]),
                "tjm": .number(Double(400 + random.next(500))),
                "depuis": .string(day(random.next(2_000))),
                "tags": .array([.string(["mobile", "backend", "audit", "regie"][index % 4])]),
                "site": .string("https://client-\(index).example"),
            ], title: "Client \(index) · \(cities[index % cities.count])", updatedAt: now)
        }
        rows["clients", default: []] += clients

        let invoiceCollection = collections.first { $0.id == "factures" }
        let invoices = (0..<max(1, count / 2)).map { index in
            let emitted = random.next(1_500)
            let days = Double(1 + random.next(20))
            let row = DataRow(id: "bulk-fac-\(index)", values: [
                "titre": .string(String(format: "F-B-%05d · Mission %d", index, index % 97)),
                "client_id": .string(clients[random.next(clients.count)].id),
                "statut": .string(statuses[random.next(statuses.count)]),
                "date_emission": .string(day(emitted)),
                "date_echeance": .string(day(emitted - 30)),
                "jours": .number(days),
                "montant_ht": .number(days * Double(450 + random.next(300))),
                "taux_tva": .number(0.2),
                "notes": .string("Facture générée \(index)"),
                "pdf": .array([.object(["name": .string("bulk-\(index).pdf"), "path": .string("factures/bulk-\(index)/bulk-\(index).pdf")])]),
            ], title: "", updatedAt: now)
            return invoiceCollection.map { DemoWorkspaceSeed.recompute(row, in: $0) } ?? row
        }
        rows["factures", default: []] += invoices

        rows["virements", default: []] += (0..<count).map { index in
            let label = merchants[random.next(merchants.count)]
            var values: [String: JSONValue] = [
                "libelle": .string("\(label) #\(index)"),
                "date": .string(day(random.next(1_100))),
                "montant": .number(Double(random.next(400_000) - 300_000) / 100),
                "categorie": .string(categories[random.next(categories.count)]),
                "compte": .string(index % 5 == 0 ? DemoWorkspaceSeed.personalBank : DemoWorkspaceSeed.businessBank),
                "rapproche": .bool(random.next(3) > 0),
            ]
            if index % 4 == 0 { values["facture_id"] = .string(invoices[random.next(invoices.count)].id) }
            return DataRow(id: "bulk-vir-\(index)", values: values, title: "\(label) #\(index)", updatedAt: now)
        }

        let types = ["carte", "virement", "prelevement", "frais"]
        let kinds = ["restaurant", "transport", "logiciel", "materiel", "impots", "salaire", "client"]
        let timestamps = ISO8601DateFormatter()
        rows["transactions"] = (0..<count).map { index in
            let label = merchants[random.next(merchants.count)]
            let amount = Double(random.next(400_000) - 300_000) / 100
            var values: [String: JSONValue] = [
                "libelle": .string("\(label) · \(index)"),
                "date": .string(timestamps.string(from: now.addingTimeInterval(-Double(index) * 3_917))),
                "montant": .number(amount),
                "sens": .string(amount < 0 ? "debit" : "credit"),
                "type": .string(types[random.next(types.count)]),
                "statut": .string(["pending", "settled", "settled", "settled", "declined"][random.next(5)]),
                "categorie": .string(kinds[random.next(kinds.count)]),
                "contrepartie": .string(label.components(separatedBy: " ").dropFirst().joined(separator: " ")),
                "reference": .string(String(format: "QNT-%08d", index * 7_919 % 100_000_000)),
                "tva": .number((abs(amount) * 0.2 * 100).rounded() / 100),
                "taux": .number(0.2),
                "carte": .string(random.next(3) == 0 ? "" : "•••• \(1_000 + random.next(9_000))"),
                "justificatif": .bool(random.next(4) > 0),
                "rapproche": .bool(random.next(3) > 0),
                "note": .string(random.next(5) == 0 ? "Note \(index)" : ""),
                "solde": .number(Double(50_000 - index * 3)),
            ]
            if index % 6 == 0 { values["facture_id"] = .string(invoices[random.next(invoices.count)].id) }
            return DataRow(id: "bulk-trx-\(index)", values: values, title: "\(label) · \(index)", updatedAt: now)
        }
    }

    private struct Generator {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(max(bound, 1)))
        }
    }
}
#endif
