import Foundation

/// Fake but plausible data for `-demo`: a freelance company's invoices, clients and transfers, 12 months of
/// savings, a few reminders and a small docs repository. Names and amounts are invented.
enum DemoWorkspaceSeed {
    struct Seed {
        var collections: [DataCollection]
        var rows: [String: [DataRow]]
        var history: [DataChange]
        var reminders: [Reminder]
        var docs: [String: (content: String, sha: String, updatedAt: Date)]
        var dirs: Set<String>
        var places: [Place]
    }

    static let homePlace = Place(id: "plc-maison", name: String(localized: "demo.data.place.home", defaultValue: "Home"), address: String(localized: "demo.data.place.homeAddress", defaultValue: "Rue des Martyrs, Paris 9th"), lat: 48.8800, lon: 2.3400, radiusM: 150)
    static let officePlace = Place(id: "plc-bureau", name: String(localized: "demo.data.place.office", defaultValue: "Office"), address: String(localized: "demo.data.place.officeAddress", defaultValue: "Rue de Paradis, Paris 10th"), lat: 48.8758, lon: 2.3520, radiusM: 120)
    static let gymPlace = Place(id: "plc-sport", name: String(localized: "demo.data.place.gym", defaultValue: "Gym"), address: String(localized: "demo.data.place.gymAddress", defaultValue: "Rue de Clichy, Paris 9th"), lat: 48.8790, lon: 2.3290, radiusM: 100)
    static var places: [Place] { [homePlace, officePlace, gymPlace] }

    static var statusOptions: [DataOption] {
        [
            DataOption(value: "brouillon", label: String(localized: "demo.data.invoiceStatus.draft", defaultValue: "Draft"), color: "#A3A1A8"),
            DataOption(value: "envoyee", label: String(localized: "demo.data.invoiceStatus.sent", defaultValue: "Sent"), color: "#3B82F6"),
            DataOption(value: "payee", label: String(localized: "demo.data.invoiceStatus.paid", defaultValue: "Paid"), color: "#1F9D57"),
            DataOption(value: "retard", label: String(localized: "demo.data.invoiceStatus.overdue", defaultValue: "Overdue"), color: "#E5484D"),
        ]
    }

    /// Account names are the stored values: the rows and the net worth dashboard share them.
    static let checkingAccount = String(localized: "demo.data.account.checking", defaultValue: "Checking account")
    static let savingsAccount = String(localized: "demo.data.account.savings", defaultValue: "Savings account")
    static let stocksAccount = String(localized: "demo.data.account.stocks", defaultValue: "Stock portfolio")
    static let lifeInsuranceAccount = String(localized: "demo.data.account.lifeInsurance", defaultValue: "Life insurance")
    static let cryptoAccount = "Crypto"
    static let businessBank = String(localized: "demo.data.bank.business", defaultValue: "Business account")
    static let personalBank = String(localized: "demo.data.bank.personal", defaultValue: "Personal account")

    static var accountOptions: [DataOption] {
        [
            DataOption(value: checkingAccount, color: "#8B8A91"),
            DataOption(value: savingsAccount, color: "#3B82F6"),
            DataOption(value: stocksAccount, color: "#FF6A2B"),
            DataOption(value: lifeInsuranceAccount, color: "#1F9D57"),
            DataOption(value: cryptoAccount, color: "#A855F7"),
        ]
    }

    static var collections: [DataCollection] {
        [
        DataCollection(id: "factures", label: String(localized: "demo.data.factures", defaultValue: "Invoices"), emoji: "🧾", count: 0, columns: [
            DataColumn(name: "titre", label: String(localized: "demo.data.factures.titre", defaultValue: "Title"), type: .text, order: 0),
            DataColumn(name: "client_id", label: String(localized: "demo.data.factures.client_id", defaultValue: "Client"), type: .ref, ref: "clients", order: 1),
            DataColumn(name: "statut", label: String(localized: "demo.data.factures.statut", defaultValue: "Status"), type: .select, options: statusOptions, order: 2),
            DataColumn(name: "date_emission", label: String(localized: "demo.data.factures.date_emission", defaultValue: "Issued"), type: .date, order: 3),
            DataColumn(name: "date_echeance", label: String(localized: "demo.data.factures.date_echeance", defaultValue: "Due"), type: .date, order: 4),
            DataColumn(name: "jours", label: String(localized: "demo.data.factures.jours", defaultValue: "Days billed"), type: .number, order: 5),
            DataColumn(name: "montant_ht", label: String(localized: "demo.data.factures.montant_ht", defaultValue: "Amount excl. VAT"), type: .money, order: 6),
            DataColumn(name: "taux_tva", label: String(localized: "demo.data.factures.taux_tva", defaultValue: "VAT rate"), type: .percent, order: 7),
            DataColumn(name: "tva", label: String(localized: "demo.data.factures.tva", defaultValue: "VAT"), type: .money, computed: true, order: 8),
            DataColumn(name: "ttc", label: String(localized: "demo.data.factures.ttc", defaultValue: "Total incl. VAT"), type: .money, computed: true, order: 9),
            DataColumn(name: "ca_ht", label: String(localized: "demo.data.factures.ca_ht", defaultValue: "Revenue excl. VAT"), type: .money, computed: true, hidden: true, order: 10),
            DataColumn(name: "annee", label: String(localized: "demo.data.factures.annee", defaultValue: "Year"), type: .number, computed: true, hidden: true, order: 11),
            DataColumn(name: "mois", label: String(localized: "demo.data.factures.mois", defaultValue: "Month"), type: .number, computed: true, hidden: true, order: 12),
            DataColumn(name: "notes", label: String(localized: "demo.data.factures.notes", defaultValue: "Notes"), type: .longtext, order: 13),
            DataColumn(name: "pdf", label: String(localized: "demo.data.factures.pdf", defaultValue: "PDF"), type: .file, order: 14),
        ], titleColumn: "titre", defaultSort: "date_emission:desc"),
        DataCollection(id: "clients", label: String(localized: "demo.data.clients", defaultValue: "Clients"), emoji: "🏢", count: 0, columns: [
            DataColumn(name: "nom", label: String(localized: "demo.data.clients.nom", defaultValue: "Name"), type: .text, order: 0),
            DataColumn(name: "statut", label: String(localized: "demo.data.clients.statut", defaultValue: "Status"), type: .select, options: [
                DataOption(value: "actif", label: String(localized: "demo.data.clientStatus.active", defaultValue: "Active"), color: "#1F9D57"),
                DataOption(value: "prospect", label: String(localized: "demo.data.clientStatus.prospect", defaultValue: "Prospect"), color: "#F59E0B"),
                DataOption(value: "pause", label: String(localized: "demo.data.clientStatus.onHold", defaultValue: "On hold"), color: "#A3A1A8"),
            ], order: 1),
            DataColumn(name: "contact", label: String(localized: "demo.data.clients.contact", defaultValue: "Contact"), type: .text, order: 2),
            DataColumn(name: "ville", label: String(localized: "demo.data.clients.ville", defaultValue: "City"), type: .text, order: 3),
            DataColumn(name: "tjm", label: String(localized: "demo.data.clients.tjm", defaultValue: "Day rate"), type: .money, order: 4),
            DataColumn(name: "depuis", label: String(localized: "demo.data.clients.depuis", defaultValue: "Client since"), type: .date, order: 5),
            DataColumn(name: "tags", label: String(localized: "demo.data.clients.tags", defaultValue: "Tags"), type: .multiselect, options: [
                DataOption(value: "mobile", label: String(localized: "demo.data.tag.mobile", defaultValue: "Mobile"), color: "#FF6A2B"),
                DataOption(value: "backend", label: String(localized: "demo.data.tag.backend", defaultValue: "Backend"), color: "#3B82F6"),
                DataOption(value: "audit", label: String(localized: "demo.data.tag.audit", defaultValue: "Audit"), color: "#A855F7"),
                DataOption(value: "regie", label: String(localized: "demo.data.tag.contracting", defaultValue: "Contracting"), color: "#1F9D57"),
            ], order: 6),
            DataColumn(name: "site", label: String(localized: "demo.data.clients.site", defaultValue: "Website"), type: .url, order: 7),
        ], titleColumn: "nom", defaultSort: "nom:asc"),
        DataCollection(id: "virements", label: String(localized: "demo.data.virements", defaultValue: "Transfers"), emoji: "💸", count: 0, columns: [
            DataColumn(name: "libelle", label: String(localized: "demo.data.virements.libelle", defaultValue: "Label"), type: .text, order: 0),
            DataColumn(name: "date", label: String(localized: "demo.data.virements.date", defaultValue: "Date"), type: .date, order: 1),
            DataColumn(name: "montant", label: String(localized: "demo.data.virements.montant", defaultValue: "Amount"), type: .money, order: 2),
            DataColumn(name: "categorie", label: String(localized: "demo.data.virements.categorie", defaultValue: "Category"), type: .select, options: [
                DataOption(value: "client", label: String(localized: "demo.data.category.client", defaultValue: "Client"), color: "#1F9D57"),
                DataOption(value: "urssaf", label: String(localized: "demo.data.category.urssaf", defaultValue: "Social charges"), color: "#F59E0B"),
                DataOption(value: "tva", label: String(localized: "demo.data.category.tva", defaultValue: "VAT"), color: "#E5484D"),
                DataOption(value: "salaire", label: String(localized: "demo.data.category.salaire", defaultValue: "Salary"), color: "#3B82F6"),
                DataOption(value: "abonnement", label: String(localized: "demo.data.category.abonnement", defaultValue: "Subscription"), color: "#A855F7"),
            ], order: 3),
            DataColumn(name: "facture_id", label: String(localized: "demo.data.virements.facture_id", defaultValue: "Invoice"), type: .ref, ref: "factures", order: 4),
            DataColumn(name: "compte", label: String(localized: "demo.data.virements.compte", defaultValue: "Account"), type: .select, options: [DataOption(value: businessBank), DataOption(value: personalBank)], order: 5),
            DataColumn(name: "rapproche", label: String(localized: "demo.data.virements.rapproche", defaultValue: "Reconciled"), type: .bool, order: 6),
        ], titleColumn: "libelle", defaultSort: "date:desc"),
        DataCollection(id: "patrimoine", label: String(localized: "demo.data.patrimoine", defaultValue: "Net worth"), emoji: "📈", count: 0, columns: [
            DataColumn(name: "libelle", label: String(localized: "demo.data.patrimoine.libelle", defaultValue: "Statement"), type: .text, order: 0),
            DataColumn(name: "mois", label: String(localized: "demo.data.patrimoine.mois", defaultValue: "Month"), type: .date, order: 1),
            DataColumn(name: "compte", label: String(localized: "demo.data.patrimoine.compte", defaultValue: "Account"), type: .select, options: accountOptions, order: 2),
            DataColumn(name: "montant", label: String(localized: "demo.data.patrimoine.montant", defaultValue: "Balance"), type: .money, order: 3),
        ], titleColumn: "libelle", defaultSort: "mois:desc"),
        ]
    }

    static func make(now: Date) -> Seed {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris") ?? .current
        let year = calendar.component(.year, from: now)
        let month = calendar.component(.month, from: now)
        let today = calendar.component(.day, from: now)

        func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: 12)) ?? now
        }
        func iso(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
        }

        // Clients
        let clients: [(id: String, nom: String, statut: String, contact: String, ville: String, tjm: Double, depuis: String, tags: [String])] = [
            ("cli-nordline", "Nordline Logistique", "actif", String(localized: "demo.data.contact.product", defaultValue: "Head of product"), "Lille", 650, "2024-03-04", ["mobile", "regie"]),
            ("cli-velocite", "Vélocité SAS", "actif", "CTO", "Paris", 700, "2025-11-17", ["backend"]),
            ("cli-paprika", "Studio Paprika", "actif", String(localized: "demo.data.contact.founder", defaultValue: "Founder"), "Nantes", 600, "2025-02-10", ["mobile", "audit"]),
            ("cli-lucie", "Brasserie Lucie", "actif", String(localized: "demo.data.contact.management", defaultValue: "Management"), "Lyon", 550, "2023-09-01", ["backend"]),
            ("cli-ferrand", "Atelier Boréal", "prospect", String(localized: "demo.data.contact.leadership", defaultValue: "Leadership"), "Bordeaux", 500, "\(year)-09-22", ["audit"]),
            ("cli-kiosk", "Kiosk Labs", "pause", String(localized: "demo.data.contact.procurement", defaultValue: "Procurement"), "Paris", 680, "2022-05-30", ["mobile"]),
        ]
        let clientRows = clients.map { client in
            DataRow(id: client.id, values: [
                "nom": .string(client.nom), "statut": .string(client.statut), "contact": .string(client.contact),
                "ville": .string(client.ville), "tjm": .number(client.tjm), "depuis": .string(client.depuis),
                "tags": .array(client.tags.map(JSONValue.string)),
                "site": .string("https://\(client.nom.lowercased().folding(options: .diacriticInsensitive, locale: nil).replacingOccurrences(of: " ", with: "-")).example"),
            ], title: client.nom, updatedAt: now)
        }

        // Invoices: Nordline every month, Vélocité from March, Paprika and Lucie now and then.
        let plan: [(client: Int, months: [Int], days: [Int])] = [
            (0, Array(1...12), [17, 15, 18, 16, 14, 19, 12, 9, 18, 16, 17, 15]),
            (1, Array(3...12), [8, 11, 12, 10, 9, 6, 12, 11, 10, 12]),
            (2, [2, 4, 6, 9, 10], [5, 4, 6, 3, 4]),
            (3, [1, 2, 5, 6, 9], [3, 4, 6, 5, 3]),
        ]
        var invoices: [DataRow] = []
        var counter = 0
        for m in 1...month {
            for entry in plan {
                guard let index = entry.months.firstIndex(of: m) else { continue }
                counter += 1
                let client = clients[entry.client]
                let days = Double(entry.days[index])
                let isCurrent = m == month
                let emission = isCurrent ? day(year, m, max(1, min(today - 2, 14))) : day(year, m, 28)
                let due = calendar.date(byAdding: .day, value: 30, to: emission)!
                var status = due < now ? "payee" : "envoyee"
                if isCurrent && entry.client == 2 { status = "brouillon" }
                if m == month - 1 && entry.client == 1 { status = "retard" }
                if m == month - 1 && entry.client == 0 && due > now { status = "envoyee" }
                let id = String(format: "fac-%03d", counter)
                let monthName = DemoWorkspaceSeed.monthNames[m - 1]
                invoices.append(recompute(DataRow(id: id, values: [
                    "titre": .string(String(format: "F-%d-%03d · ", year, counter) + String(localized: "\(monthName) work")),
                    "client_id": .string(client.id),
                    "statut": .string(status),
                    "date_emission": .string(iso(emission)),
                    "date_echeance": .string(iso(due)),
                    "jours": .number(days),
                    "montant_ht": .number(days * client.tjm),
                    "taux_tva": .number(0.2),
                    "notes": .string(String(localized: "\(monthName) work: \(Int(days)) days at \(Int(client.tjm)) € excl. VAT.")),
                    "pdf": .array([.object(["name": .string("\(id).pdf"), "path": .string("factures/\(id)/\(id).pdf")])]),
                ], title: "", updatedAt: emission), in: collections[0]))
            }
        }

        // Transfers: client payments plus the usual outgoings.
        var transfers: [DataRow] = []
        func transfer(_ label: String, _ date: Date, _ amount: Double, _ category: String, invoice: String? = nil, account: String = DemoWorkspaceSeed.businessBank) {
            guard date <= now else { return }
            var values: [String: JSONValue] = [
                "libelle": .string(label), "date": .string(iso(date)), "montant": .number(amount),
                "categorie": .string(category), "compte": .string(account), "rapproche": .bool(invoice != nil || category != "client"),
            ]
            if let invoice { values["facture_id"] = .string(invoice) }
            transfers.append(DataRow(id: "vir-\(String(format: "%03d", transfers.count + 1))", values: values, title: label, updatedAt: date))
        }
        for invoice in invoices where invoice["statut"].string == "payee" {
            let due = invoice["date_echeance"].string.flatMap { DemoWorkspaceSeed.parseDay($0, calendar: calendar) } ?? now
            let clientName = clients.first { $0.id == invoice["client_id"].string }?.nom ?? String(localized: "demo.data.client", defaultValue: "Client")
            transfer(String(localized: "Payment from \(clientName)"), calendar.date(byAdding: .day, value: -4, to: due)!, invoice["ttc"].double ?? 0, "client", invoice: invoice.id)
        }
        for m in 1...month {
            transfer(String(localized: "demo.data.transfer.salary", defaultValue: "Salary"), day(year, m, 27), -3_650, "salaire")
            transfer(String(localized: "demo.data.transfer.hosting", defaultValue: "Cloud hosting"), day(year, m, 3), -42.9, "abonnement")
            transfer(String(localized: "demo.data.transfer.bankFee", defaultValue: "Bank · subscription"), day(year, m, 1), -29, "abonnement")
            if m % 3 == 1 {
                transfer(String(localized: "Social charges, Q\((m + 2) / 3)"), day(year, m, 5), -2_870, "urssaf")
            }
            if [2, 5, 8, 11].contains(m) {
                transfer(String(localized: "demo.data.transfer.vat", defaultValue: "Tax office · VAT"), day(year, m, 19), -(4_600 + Double(m) * 85), "tva")
            }
        }
        transfer("Apple Developer Program", day(year, 3, 12), -99, "abonnement")

        // Savings: 12 monthly statements per account.
        var savings: [DataRow] = []
        let starts: [(account: String, base: Double, step: Double, wobble: Double)] = [
            (checkingAccount, 4_200, 35, 800), (savingsAccount, 18_500, 150, 0), (stocksAccount, 24_300, 480, 1_300),
            (lifeInsuranceAccount, 12_800, 260, 240), (cryptoAccount, 1_900, 45, 600),
        ]
        let noise: [Double] = [0.1, -0.4, 0.6, 0.2, -0.8, 0.9, 0.3, -0.2, 0.7, -0.5, 0.4, 1]
        for offset in 0..<12 {
            let date = calendar.date(byAdding: .month, value: offset - 11, to: day(year, month, 1))!
            let label = date.formatted(.dateTime.month(.abbreviated).year().locale(.current)).capitalized
            for (index, start) in starts.enumerated() {
                let wiggle = noise[(offset + index * 3) % noise.count] * start.wobble
                let amount = (start.base + start.step * Double(offset) + wiggle).rounded()
                savings.append(DataRow(id: "pat-\(offset)-\(index)", values: [
                    "libelle": .string("\(label) · \(start.account)"), "mois": .string(iso(date)),
                    "compte": .string(start.account), "montant": .number(amount),
                ], title: "\(label) · \(start.account)", updatedAt: date))
            }
        }

        let rows = ["factures": invoices, "clients": clientRows, "virements": transfers, "patrimoine": savings]

        // A bit of history so the row screen has something to show.
        var history: [DataChange] = []
        if let paid = invoices.last(where: { $0["statut"].string == "payee" }) {
            history.append(DataChange(id: "chg-seed-1", at: calendar.date(byAdding: .day, value: -6, to: now)!, collection: "factures", rowId: paid.id,
                                      op: .insert, changes: ["titre": [.null, paid["titre"]], "montant_ht": [.null, paid["montant_ht"]]], source: "agent"))
            history.append(DataChange(id: "chg-seed-2", at: calendar.date(byAdding: .day, value: -2, to: now)!, collection: "factures", rowId: paid.id,
                                      op: .update, changes: ["statut": [.string("envoyee"), .string("payee")]], source: "agent"))
        }
        for invoice in invoices.suffix(4) {
            history.append(DataChange(id: "chg-\(invoice.id)-a", at: calendar.date(byAdding: .hour, value: -30, to: now)!, collection: "factures", rowId: invoice.id,
                                      op: .insert, changes: ["titre": [.null, invoice["titre"]], "montant_ht": [.null, invoice["montant_ht"]]], source: "agent"))
            if let days = invoice["jours"].double {
                history.append(DataChange(id: "chg-\(invoice.id)-b", at: calendar.date(byAdding: .hour, value: -5, to: now)!, collection: "factures", rowId: invoice.id,
                                          op: .update, changes: ["jours": [.number(days - 1), .number(days)], "montant_ht": [.number((invoice["montant_ht"].double ?? 0) - 650), invoice["montant_ht"]]], source: "app"))
            }
        }

        return Seed(collections: collections, rows: rows, history: history, reminders: reminders(now: now, calendar: calendar),
                    docs: docs(now: now), dirs: ["lumen", "homelab", travelDir], places: places)
    }

    static var monthNames: [String] {
        let formatter = DateFormatter()
        formatter.locale = .current
        return formatter.standaloneMonthSymbols
    }

    static func parseDay(_ text: String, calendar: Calendar) -> Date? {
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// What the gateway's `v_<table>` views add.
    static func recompute(_ row: DataRow, in collection: DataCollection) -> DataRow {
        var row = row
        if collection.id == "factures" {
            let ht = row["montant_ht"].double ?? 0
            let rate = row["taux_tva"].double ?? 0.2
            let tva = (ht * rate * 100).rounded() / 100
            row.values["ca_ht"] = .number(ht)
            row.values["tva"] = .number(tva)
            row.values["ttc"] = .number(ht + tva)
            let date = row["date_emission"].string ?? ""
            row.values["annee"] = Int(date.prefix(4)).map { .number(Double($0)) } ?? .null
            row.values["mois"] = Int(date.dropFirst(5).prefix(2)).map { .number(Double($0)) } ?? .null
        }
        row.title = row[collection.titleColumn].string ?? String(localized: "Untitled")
        return row
    }

    // MARK: Reminders

    static func reminders(now: Date, calendar: Calendar) -> [Reminder] {
        let start = calendar.startOfDay(for: now)
        func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let day = calendar.date(byAdding: .day, value: dayOffset, to: start)!
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day)!
        }
        // Today's items stay ahead of "now" whatever time the demo runs.
        func later(_ hour: Int, _ fallbackMinutes: Int) -> Date {
            let wanted = at(0, hour)
            if wanted > now { return wanted }
            return min(now.addingTimeInterval(TimeInterval(fallbackMinutes * 60)), at(0, 23, 59))
        }
        func nextWeekday(_ weekday: Int, _ hour: Int) -> Date {
            var components = DateComponents()
            components.weekday = weekday
            components.hour = hour
            return calendar.nextDate(after: now, matching: components, matchingPolicy: .nextTime) ?? at(3, hour)
        }
        let firstOfNextMonth = calendar.date(byAdding: .month, value: 1, to: calendar.date(from: calendar.dateComponents([.year, .month], from: now))!)!
        func make(_ id: String, _ title: String, list: String, due: Date?, priority: Int = 0, repeat rule: String? = nil, notes: String? = nil,
                  done: Date? = nil, place: Place? = nil, trigger: String? = nil) -> Reminder {
            Reminder(id: id, title: title, notes: notes, dueAt: due, repeat: rule, list: list, priority: priority, doneAt: done, snoozedUntil: nil,
                     createdAt: calendar.date(byAdding: .day, value: -4, to: now)!, updatedAt: now, place: place?.asReminderPlace, placeTrigger: trigger)
        }
        let lumen = "Lumen Studio"
        let home = String(localized: "demo.reminders.list.home", defaultValue: "Home")
        let health = String(localized: "demo.reminders.list.health", defaultValue: "Health")
        let personal = String(localized: "demo.reminders.list.personal", defaultValue: "Personal")
        let travel = String(localized: "demo.reminders.list.travel", defaultValue: "Travel")
        return [
            make("rem-01", String(localized: "Chase Vélocité about the September invoice"), list: lumen, due: at(-1, 10), priority: 2,
                 notes: String(localized: "5 days past due. Resend the PDF with the bank details.")),
            make("rem-02", String(localized: "Renew the home insurance"), list: home, due: at(-3, 9), priority: 1),
            make("rem-03", String(localized: "Declare this quarter's revenue"), list: lumen, due: later(11, 25), priority: 3,
                 notes: String(localized: "The amount is in the Lumen Studio dashboard, under Revenue excl. VAT.")),
            make("rem-04", String(localized: "Call the physio to move the session"), list: health, due: later(14, 70)),
            make("rem-05", String(localized: "Buy AA batteries for the smoke detector"), list: home, due: later(18, 140), place: places[1], trigger: "leave"),
            make("rem-06", String(localized: "Water the balcony plants"), list: home, due: later(19, 190), repeat: "0 19 * * 1,4"),
            make("rem-07", String(localized: "Send the October invoice to Nordline"), list: lumen, due: at(1, 9), priority: 2),
            make("rem-08", String(localized: "Dentist, annual checkup"), list: health, due: at(2, 14, 30), notes: String(localized: "12 rue des Lilas, 2nd floor.")),
            make("rem-09", String(localized: "Weekly review"), list: personal, due: nextWeekday(2, 8), repeat: "0 8 * * 1"),
            make("rem-10", String(localized: "Get the visa paperwork ready for Japan"), list: travel, due: at(5, 18), priority: 1),
            make("rem-11", String(localized: "Pay the VAT"), list: lumen, due: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: firstOfNextMonth), priority: 2, repeat: "0 9 1 * *"),
            make("rem-12", String(localized: "Neighbors' party 🎉"), list: personal, due: at(9, 9), repeat: "yearly"),
            make("rem-13", String(localized: "Sort the summer photos"), list: personal, due: nil),
            make("rem-14", String(localized: "Read “The Quiet Studio”"), list: personal, due: nil),
            make("rem-15", String(localized: "Back up the homelab Postgres database"), list: "Homelab", due: at(3, 21), repeat: "weekly"),
            make("rem-19", String(localized: "Pick up the parcel from the concierge"), list: home, due: nil, priority: 1, place: places[0], trigger: "arrive"),
            make("rem-20", String(localized: "Send the weekly recap to Nordline"), list: lumen, due: nil, repeat: "0 18 * * 5", place: places[1], trigger: "leave"),
            make("rem-16", String(localized: "Order the 2 m USB-C cable"), list: personal, due: at(-1, 12), done: now.addingTimeInterval(-3600 * 3)),
            make("rem-17", String(localized: "Approve the Atelier Boréal quote"), list: lumen, due: at(-2, 10), done: now.addingTimeInterval(-3600 * 26)),
            make("rem-18", String(localized: "Cancel the gym membership"), list: personal, due: at(-4, 9), done: now.addingTimeInterval(-3600 * 70)),
        ]
    }

    // MARK: Docs

    static var travelDir: String { String(localized: "demo.docs.dir.travel", defaultValue: "travel") }

    static func docs(now: Date) -> [String: (content: String, sha: String, updatedAt: Date)] {
        let files: [(String, String, Double)] = [
            ("lumen/plan-2026.md", planDoc, 2),
            (String(localized: "demo.docs.path.billing", defaultValue: "lumen/billing.md"), billingDoc, 30),
            ("lumen/clients.md", clientsDoc, 80),
            ("homelab/dev.md", devDoc, 6),
            (String(localized: "demo.docs.path.backups", defaultValue: "homelab/backups.md"), backupsDoc, 14),
            (String(localized: "demo.docs.path.japan", defaultValue: "travel/japan-2027.md"), japanDoc, 1),
            (String(localized: "demo.docs.path.packing", defaultValue: "travel/packing-list.md"), packingDoc, 9),
            (String(localized: "demo.docs.path.guide", defaultValue: "documents-guide.md"), guideDoc, 0.1),
            ("inbox.md", inboxDoc, 0.2),
        ]
        var result: [String: (content: String, sha: String, updatedAt: Date)] = [:]
        for (index, file) in files.enumerated() {
            result[file.0] = (file.1, String(format: "a%09d", index * 7919), now.addingTimeInterval(-file.2 * 86400))
        }
        return result
    }

    static var planDoc: String {
        String(localized: "demo.docs.plan", defaultValue: """
        ---
        title: Lumen Studio 2026 plan
        tags: [lumen, goals]
        ---
        # Lumen Studio 2026 plan

        Goal for the year: **€200k in revenue excl. VAT** with three recurring clients at most, and a real month off in the summer.

        > [!NOTE]
        > The latest numbers are in the [Lumen Studio dashboard](nuo://dashboard/lumen) and the [Invoices](nuo://data/factures) collection.

        ## Goals

        | Metric | Target | Where we are |
        |---|---|---|
        | Revenue excl. VAT | €200,000 | see dashboard |
        | Average day rate | €650 | €640 |
        | Payment time | < 35 days | 38 days |

        ## This quarter

        - [x] Renew the Nordline contract through June
        - [x] Switch invoicing to 30 days end of month
        - [ ] Follow up with Vélocité every time, 5 days after the due date
        - [ ] Prepare the “mobile audit” offer for Atelier Boréal

        ## Principles

        1. No more than 4 billed days a week.
        2. Always a signed quote before starting.
        3. The agents keep the invoices up to date, I approve.

        > The best client is the one who pays on time.

        ### Quick math

        ```sql
        SELECT sum(ca_ht) FROM v_factures WHERE annee = 2026;
        ```
        """)
    }

    static var billingDoc: String {
        String(localized: "demo.docs.billing", defaultValue: """
        # Invoicing

        A monthly process, mostly handled by Cobot.

        1. On the 28th, Cobot creates the month's invoices from the logged days.
        2. I review them in **Nuo › Data › Invoices** and set the status to *Sent*.
        3. When the payment arrives, Cobot reconciles it and sets it to *Paid*.

        > [!TIP]
        > An overdue invoice shows up in red on the dashboard.

        ```bash
        nuo-cli invoices draft --month 2026-10
        ```
        """)
    }

    static var clientsDoc: String {
        String(localized: "demo.docs.clients", defaultValue: """
        # Clients

        The live list is in [the Clients collection](nuo://data/clients).

        - Nordline: mobile contracting, renewed through June.
        - Vélocité: Go backend, often pays late.

        """)
    }

    static var devDoc: String {
        String(localized: "demo.docs.dev", defaultValue: """
        # Dev server

        The homelab's main machine: Ryzen 7, 64 GB, Debian 13.

        ![Homelab rack](rack.jpg)

        ## Services

        | Service | Port | Notes |
        |---|---|---|
        | Nuo Gateway | 8790 | behind Caddy |
        | Postgres | 5432 | backed up every night |
        | Grafana | 3000 | Telegram alerts |

        ```bash
        systemctl --user status nuo-gateway
        journalctl --user -u nuo-gateway -f
        ```

        > [!WARNING]
        > Never expose Postgres outside the local network.
        """)
    }

    static var backupsDoc: String {
        String(localized: "demo.docs.backups", defaultValue: """
        # Backups

        > [!WARNING]
        > Restore a backup at least once a quarter.

        | What | Where | How often |
        |---|---|---|
        | Postgres | NAS + B2 | daily |
        | Docs (git) | private GitHub | on every commit |
        | Photos | NAS | weekly |

        """)
    }

    static var japanDoc: String {
        String(localized: "demo.docs.japan", defaultValue: """
        # Japan 2027

        Two weeks at the end of March, for the cherry blossoms.

        ## Itinerary

        | Days | City | Stay |
        |---|---|---|
        | 1-4 | Tokyo | Shibuya |
        | 5-7 | Hakone | ryokan |
        | 8-11 | Kyoto | Gion |
        | 12-14 | Osaka | Namba |

        ## To do

        - [x] Book the time off
        - [ ] Book the flights (price alert set)
        - [ ] JR Pass or single tickets?
        - [ ] Book the ryokan in Hakone

        > [!NOTE]
        > The Travel bot checks Paris → Tokyo flight prices every morning.
        """)
    }

    static var packingDoc: String {
        String(localized: "demo.docs.packing", defaultValue: """
        # Packing list

        - [x] Passport
        - [x] Type A adapter
        - [ ] Power bank
        - [ ] Medication
        - [ ] Suica card (top it up)

        """)
    }

    static var guideDoc: String {
        String(localized: "demo.docs.guide", defaultValue: """
        # Documents guide

        Write right in the page: type **/** to add a heading, a list, a table, an image or a file. Select text to give it a <span style="color: blue">color</span> or to <mark>highlight</mark> it.

        > [!TIP]
        > 💡 Everything saves on its own, a few moments after each change.

        ## This week

        - [x] Review the <span style="color: red">**Nordline quote**</span>
        - [ ] Prepare Monday's meeting
        - [ ] Sort the cabin photos

        <details>
        <summary>How does it work for the agents?</summary>

        Documents stay Markdown files: colors are `<span>` tags, callouts are `> [!NOTE]` quotes.

        </details>

        | Room | Budget | Status |
        |---|---|---|
        | Kitchen | €4,000 | <mark style="background: green">done</mark> |
        | Living room | €1,500 | in progress |

        ![The cabin in winter](_files/cabin.jpg)

        [📎 nordline-quote.pdf](_files/nordline-quote.pdf)

        [🔗 Swift documentation](https://swift.org/documentation/)

        """)
    }

    static var inboxDoc: String {
        String(localized: "demo.docs.inbox", defaultValue: """
        # Inbox

        Quick notes to sort.

        - Idea: a “left to collect” widget on the Lock Screen
        - Compare prices for a bigger cloud server

        """)
    }
}

enum DemoDashboards {
    static var lumenDescription: String { String(localized: "demo.dashboard.lumenDescription", defaultValue: "Revenue, VAT, transfers") }
    static var networthTitle: String { String(localized: "demo.dashboard.networth", defaultValue: "Net worth") }
    static var networthDescription: String { String(localized: "demo.dashboard.networthDescription", defaultValue: "Accounts and savings, 12 months") }

    /// Groups `(x, y, s)` rows into series like the gateway does with an `s` column.
    private static func series(_ points: [(x: String, y: Double, s: String)], single name: String? = nil) -> [DashboardBlock.Series] {
        var order: [String] = []
        var grouped: [String: [DashboardBlock.Point]] = [:]
        for point in points {
            let key = name ?? point.s
            if grouped[key] == nil { order.append(key) }
            grouped[key, default: []].append(DashboardBlock.Point(x: .string(point.x), y: point.y))
        }
        return order.map { DashboardBlock.Series(name: $0, points: grouped[$0]!) }
    }

    static func lumen(rows: [String: [DataRow]]) -> Dashboard {
        let invoices = (rows["factures"] ?? []).filter { $0.archivedAt == nil }
        let clients = Dictionary(uniqueKeysWithValues: (rows["clients"] ?? []).map { ($0.id, $0.title) })
        let year = invoices.compactMap { $0["annee"].double }.max().map(Int.init) ?? 2026
        let ofYear = invoices.filter { Int($0["annee"].double ?? 0) == year }
        let total = ofYear.reduce(0) { $0 + ($1["ca_ht"].double ?? 0) }
        let tva = ofYear.reduce(0) { $0 + ($1["tva"].double ?? 0) }
        let pending = ofYear.filter { ["envoyee", "retard"].contains($0["statut"].string ?? "") }.reduce(0) { $0 + ($1["ttc"].double ?? 0) }

        var byMonthClient: [String: [String: Double]] = [:]
        for invoice in ofYear {
            let month = String((invoice["date_emission"].string ?? "").prefix(7))
            let client = clients[invoice["client_id"].string ?? ""] ?? "?"
            byMonthClient[month, default: [:]][client, default: 0] += invoice["ca_ht"].double ?? 0
        }
        let clientOrder = ["Nordline Logistique", "Vélocité SAS", "Studio Paprika", "Brasserie Lucie"]
        let bars = clientOrder.flatMap { client in
            byMonthClient.keys.sorted().map { (x: $0, y: byMonthClient[$0]?[client] ?? 0, s: client) }
        }
        var byClient: [String: Double] = [:]
        for invoice in ofYear { byClient[clients[invoice["client_id"].string ?? ""] ?? "?", default: 0] += invoice["ca_ht"].double ?? 0 }
        let donut = byClient.sorted { $0.value > $1.value }.map { (x: $0.key, y: $0.value, s: "") }

        var balance = 14_200.0
        var cash: [(x: String, y: Double, s: String)] = []
        let transfers = (rows["virements"] ?? []).sorted { ($0["date"].string ?? "") < ($1["date"].string ?? "") }
        for month in Set(transfers.compactMap { $0["date"].string.map { String($0.prefix(7)) } }).sorted() {
            balance += transfers.filter { $0["date"].string?.hasPrefix(month) == true }.reduce(0) { $0 + ($1["montant"].double ?? 0) }
            cash.append((month, balance.rounded(), ""))
        }

        let latest = ofYear.sorted { ($0["date_emission"].string ?? "") > ($1["date_emission"].string ?? "") }.prefix(6).map { invoice -> [JSONValue] in
            [.string(invoice.id), invoice["titre"], .string(clients[invoice["client_id"].string ?? ""] ?? ""), invoice["statut"], invoice["ttc"], invoice["date_emission"]]
        }
        let byClientTitle = String(localized: "demo.dashboard.byClient", defaultValue: "By client")
        let cashTitle = String(localized: "demo.dashboard.cash", defaultValue: "Business account balance")
        return Dashboard(slug: "lumen", title: "Lumen Studio \(year)", emoji: "💼", description: lumenDescription, blocks: [
            DashboardBlock(type: .number, title: String(localized: "Revenue excl. VAT, \(String(year))"), format: "money", value: .number(total)),
            DashboardBlock(type: .number, title: String(localized: "demo.dashboard.toCollect", defaultValue: "To collect"), format: "money", value: .number(pending)),
            DashboardBlock(type: .number, title: String(localized: "demo.dashboard.vatCollected", defaultValue: "VAT collected"), format: "money", value: .number(tva)),
            DashboardBlock(type: .bar, title: String(localized: "demo.dashboard.revenueByMonth", defaultValue: "Revenue by month, excl. VAT"), format: "money", series: series(bars)),
            DashboardBlock(type: .donut, title: byClientTitle, format: "money", series: series(donut, single: byClientTitle)),
            DashboardBlock(type: .line, title: cashTitle, format: "money", series: series(cash, single: cashTitle)),
            DashboardBlock(type: .table, title: String(localized: "demo.dashboard.latestInvoices", defaultValue: "Latest invoices"), collection: "factures",
                           columns: ["id", "titre", "client", "statut", "ttc", "date_emission"], rows: Array(latest)),
        ])
    }

    static func patrimoine(rows: [String: [DataRow]]) -> Dashboard {
        let statements = (rows["patrimoine"] ?? []).filter { $0.archivedAt == nil }
        let months = Set(statements.compactMap { $0["mois"].string.map { String($0.prefix(7)) } }).sorted()
        func total(_ month: String) -> Double {
            statements.filter { $0["mois"].string?.hasPrefix(month) == true }.reduce(0) { $0 + ($1["montant"].double ?? 0) }
        }
        let last = months.last ?? ""
        let previous = months.dropLast().last ?? ""
        let totals = months.map { (x: $0, y: total($0), s: "") }
        let accounts = [DemoWorkspaceSeed.stocksAccount, DemoWorkspaceSeed.savingsAccount, DemoWorkspaceSeed.lifeInsuranceAccount, DemoWorkspaceSeed.cryptoAccount]
        let byAccount = accounts.flatMap { account in
            months.map { month in
                (x: month, y: statements.first { $0["mois"].string?.hasPrefix(month) == true && $0["compte"].string == account }?["montant"].double ?? 0, s: account)
            }
        }
        let latest = statements.filter { $0["mois"].string?.hasPrefix(last) == true }.sorted { ($0["montant"].double ?? 0) > ($1["montant"].double ?? 0) }
        let donut = latest.map { (x: $0["compte"].string ?? "", y: $0["montant"].double ?? 0, s: "") }
        let items = latest.map { row -> DashboardBlock.Item in
            let before = statements.first { $0["mois"].string?.hasPrefix(previous) == true && $0["compte"] == row["compte"] }?["montant"].double ?? 0
            let delta = (row["montant"].double ?? 0) - before
            let sign = delta >= 0 ? "+" : "−"
            let amount = "\(sign)\(Int(abs(delta)).formatted(.number.locale(.current)))"
            return DashboardBlock.Item(title: row["compte"].string ?? "", subtitle: String(localized: "\(amount) € this month"),
                                       value: row["montant"], id: row.id)
        }
        let split = String(localized: "demo.dashboard.split", defaultValue: "Allocation")
        return Dashboard(slug: "patrimoine", title: networthTitle, emoji: "📈", description: networthDescription, blocks: [
            DashboardBlock(type: .number, title: String(localized: "demo.dashboard.totalNetworth", defaultValue: "Total net worth"), format: "money", value: .number(total(last))),
            DashboardBlock(type: .number, title: String(localized: "demo.dashboard.thisMonth", defaultValue: "This month"), format: "money", value: .number(total(last) - total(previous))),
            DashboardBlock(type: .line, title: String(localized: "demo.dashboard.overTime", defaultValue: "Over time"), format: "money", series: series(totals, single: "Total")),
            DashboardBlock(type: .line, title: String(localized: "demo.dashboard.byInvestment", defaultValue: "By investment"), format: "money", series: series(byAccount)),
            DashboardBlock(type: .donut, title: split, format: "money", series: series(donut, single: split)),
            DashboardBlock(type: .list, title: String(localized: "demo.dashboard.accounts", defaultValue: "Accounts"), format: "money", collection: "patrimoine", items: items),
        ])
    }
}
