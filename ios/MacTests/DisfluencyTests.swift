import Testing

struct DisfluencyTests {
    @Test func anOpeningHesitationGoesAndTheSentenceStartsOnACapital() {
        #expect(Disfluency.strip("Euh, rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF.")
            == "Rappelle-moi d'appeler Julie Martin demain à 9 h pour la facture EDF.")
        #expect(Disfluency.strip("Heu... bon, on décale le point hebdo à jeudi.") == "Bon, on décale le point hebdo à jeudi.")
    }

    @Test func aHesitationFramedByCommasTakesThemAlong() {
        #expect(Disfluency.strip("Je voudrais, euh, réserver une table pour quatre vendredi soir.")
            == "Je voudrais réserver une table pour quatre vendredi soir.")
        #expect(Disfluency.strip("Bon, euh... on garde la date du 24 pour la bêta.") == "Bon, on garde la date du 24 pour la bêta.")
        #expect(Disfluency.strip("Envoie la facture à, hum, Hugo Bernard.") == "Envoie la facture à Hugo Bernard.")
    }

    @Test func aHesitationEndingASentenceLeavesItsFullStop() {
        #expect(Disfluency.strip("D'accord pour mardi, hum. On en reparle lundi.") == "D'accord pour mardi. On en reparle lundi.")
        #expect(Disfluency.strip("Tu peux préparer la liste des testeurs, euh ?") == "Tu peux préparer la liste des testeurs ?")
        #expect(Disfluency.strip("Hmm. D'accord, je m'en occupe.") == "D'accord, je m'en occupe.")
    }

    @Test func severalHesitationsInARowAllGo() {
        #expect(Disfluency.strip("Euh, euh, mmh, prépare une séance de fractionné pour jeudi.") == "Prépare une séance de fractionné pour jeudi.")
        #expect(Disfluency.strip("Rappelle à Coach, euh, que je cours, hmm, jeudi matin.") == "Rappelle à Coach que je cours jeudi matin.")
        #expect(Disfluency.strip("Euhhh.") == "")
    }

    @Test func englishFillersGoToo() {
        #expect(Disfluency.strip("Um, can you move the dentist to Friday, uh, afternoon?", language: "en") == "Can you move the dentist to Friday afternoon?")
    }

    @Test func wordsThatOnlyLookLikeHesitationsStay() {
        let kept = [
            "À quelle heure part le train pour Lyon ?",
            "Ajoute du houmous et du Hummus à la liste de courses.",
            "Le joint fait 5 mm, commande-le chez Leroy Merlin.",
            "Hum-hum, approuve-t-il en souriant.",
            "Heureusement, Hugo a gardé le reçu.",
            "Le Humvee de la démonstration arrive lundi.",
            "Mhz ou MHz, vérifie la fiche technique.",
        ]
        for text in kept { #expect(Disfluency.strip(text) == text) }
    }

    @Test func humAsAWordStaysInEnglish() {
        #expect(Disfluency.strip("I can hear a hum in the engine.") == "I can hear a hum in the engine.")
        #expect(Disfluency.strip("Can you hum the tune?") == "Can you hum the tune?")
        #expect(Disfluency.strip("Hum, can you send it tonight?") == "Can you send it tonight?")
    }

    @Test func acronymsAndUnitsThatLookLikeHesitationsStay() {
        #expect(Disfluency.strip("Rendez-vous à UM demain.") == "Rendez-vous à UM demain.")
        #expect(Disfluency.strip("HM Treasury a répondu.") == "HM Treasury a répondu.")
        #expect(Disfluency.strip("Le trait fait 5 um de large.") == "Le trait fait 5 um de large.")
    }

    @Test func aNonBreakingSpaceBeforeTheQuestionMarkIsKept() {
        #expect(Disfluency.strip("Tu viens, euh\u{00A0}?") == "Tu viens\u{00A0}?")
        #expect(Disfluency.strip("Tu viens, euh\u{202F}?") == "Tu viens\u{202F}?")
    }

    @Test func theSpeakersOwnCommaAfterASingleWordStays() {
        #expect(Disfluency.strip("Oui, euh, euh, non.") == "Oui, non.")
        #expect(Disfluency.strip("Bonjour, euh, Julie.") == "Bonjour, Julie.")
    }

    @Test func aHesitationOnItsOwnLineLeavesACapital() {
        #expect(Disfluency.strip("Euh\nbonjour") == "Bonjour")
    }

    @Test func umAndUhAreWordsInOtherLanguages() {
        #expect(Disfluency.strip("Wir treffen uns um 9 Uhr.", language: "de") == "Wir treffen uns um 9 Uhr.")
        #expect(Disfluency.strip("Eu quero um café.", language: "pt") == "Eu quero um café.")
        #expect(Disfluency.strip("Eu quero um café.") == "Eu quero um café.")
        #expect(Disfluency.strip("Euh, je quero um café.", language: "pt") == "Je quero um café.")
    }

    @Test func hesitationsInARowGoTogether() {
        #expect(Disfluency.strip("C'est, euh, hum, compliqué.", language: "fr") == "C'est compliqué.")
    }

    @Test func aBrandNameKeepsItsLowerCaseFirstLetter() {
        #expect(Disfluency.strip("Euh, iPhone 16 ou 17 ?", language: "fr") == "iPhone 16 ou 17 ?")
        #expect(Disfluency.strip("Euh, eBay a remboursé.", language: "fr") == "eBay a remboursé.")
    }

    @Test func aQuotedHesitationIsWhatWasSaid() {
        #expect(Disfluency.strip("Il a dit « euh » trois fois.", language: "fr") == "Il a dit « euh » trois fois.")
        #expect(Disfluency.strip("Il a dit \"um\" again.", language: "en") == "Il a dit \"um\" again.")
    }

    @Test func anAddressIsNotAHesitation() {
        #expect(Disfluency.strip("Écris à um@example.com demain.", language: "fr") == "Écris à um@example.com demain.")
        #expect(Disfluency.strip("Le fichier euh.txt est prêt.", language: "fr") == "Le fichier euh.txt est prêt.")
    }

    @Test func bracketsThatOnlyHeldAHesitationGoToo() {
        #expect(Disfluency.strip("(euh) bon, on y va.", language: "fr") == "Bon, on y va.")
        #expect(Disfluency.strip("Alors (euh) bon, on y va.", language: "fr") == "Alors bon, on y va.")
    }

    @Test func aLinkIsNotAHesitation() {
        #expect(Disfluency.strip("Ouvre https://exemple.fr/recherche?q=euh&page=2 ce soir.", language: "fr") == "Ouvre https://exemple.fr/recherche?q=euh&page=2 ce soir.")
        #expect(Disfluency.strip("Le lien finit par #euh.", language: "fr") == "Le lien finit par #euh.")
    }

    @Test func aLongTranscriptIsCleanedInOnePass() {
        let sentence = "Euh, on valide le devis de Julie Martin, hum, pour jeudi. "
        let text = String(repeating: sentence, count: 4_000)
        let clock = ContinuousClock.now
        let clean = Disfluency.strip(text, language: "fr")
        let elapsed = ContinuousClock.now - clock
        print("Disfluency: \(text.count) characters in \(elapsed)")
        #expect(!clean.contains("euh") && !clean.contains("Euh") && !clean.contains("hum"))
        #expect(clean.hasPrefix("On valide le devis de Julie Martin pour jeudi. On valide"))
        #expect(elapsed < .seconds(2))
    }

    @Test func aHesitationAfterANumberGoesUnlessItIsAUnit() {
        #expect(Disfluency.strip("On se voit le 12 euh le 13 novembre.", language: "fr") == "On se voit le 12 le 13 novembre.")
        #expect(Disfluency.strip("Le devis fait 4 200 euh euros.", language: "fr") == "Le devis fait 4 200 euros.")
        #expect(Disfluency.strip("La couche fait 5 um d'épaisseur.", language: "fr") == "La couche fait 5 um d'épaisseur.")
    }

    @Test func numbersOnBothSidesKeepTheirComma() {
        #expect(Disfluency.strip("J'en veux 5, euh, 6 ou 7.", language: "fr") == "J'en veux 5, 6 ou 7.")
        #expect(Disfluency.strip("Ça coûte 15, euh, 20 euros.", language: "fr") == "Ça coûte 15, 20 euros.")
        #expect(Disfluency.strip("5 um, euh, 6", language: "fr") == "5 um, 6")
        #expect(Disfluency.strip("Prends 2 hm, hum, et reviens.", language: "fr") == "Prends 2 hm et reviens.")
    }

    @Test func aPrepositionBeforeTheHesitationLosesTheComma() {
        #expect(Disfluency.strip("Rappelle-moi le 12 à, euh, 14 h pour la facture EDF.", language: "fr") == "Rappelle-moi le 12 à 14 h pour la facture EDF.")
        #expect(Disfluency.strip("La réunion du 3 est décalée de, euh, 2 jours.", language: "fr") == "La réunion du 3 est décalée de 2 jours.")
        #expect(Disfluency.strip("Le devis de 4 200 € passe à, hum, 4 500 €.", language: "fr") == "Le devis de 4 200 € passe à 4 500 €.")
        #expect(Disfluency.strip("Book room 4 for, um, 3 people.", language: "en") == "Book room 4 for 3 people.")
    }

    @Test func aNumberWithItsUnitKeepsTheComma() {
        #expect(Disfluency.strip("Plutôt 9 h, euh, 10 h.", language: "fr") == "Plutôt 9 h, 10 h.")
        #expect(Disfluency.strip("Entre 4 200 €, euh, 4 500 €.", language: "fr") == "Entre 4 200 €, 4 500 €.")
        #expect(Disfluency.strip("5 um, euh, 6 um", language: "fr") == "5 um, 6 um")
    }

    @Test func aNumberAndItsUnitInWordsKeepTheComma() {
        #expect(Disfluency.strip("Rendez-vous à 10 heures, euh, 11 heures.", language: "fr") == "Rendez-vous à 10 heures, 11 heures.")
        #expect(Disfluency.strip("Ça fait 5 euros, euh, 6 euros.", language: "fr") == "Ça fait 5 euros, 6 euros.")
        #expect(Disfluency.strip("Compte 15 minutes, euh, 20 minutes.", language: "fr") == "Compte 15 minutes, 20 minutes.")
        #expect(Disfluency.strip("Il faut 2 L, euh, 3 L d'eau.", language: "fr") == "Il faut 2 L, 3 L d'eau.")
        #expect(Disfluency.strip("Prends 5 pommes, euh, 6 poires.", language: "fr") == "Prends 5 pommes, 6 poires.")
        // A small word after the number is not a unit: the comma only framed the hesitation.
        #expect(Disfluency.strip("Rappelle-moi le 12 à, euh, 14 h.", language: "fr") == "Rappelle-moi le 12 à 14 h.")
        #expect(Disfluency.strip("Book room 4 FOR, um, 3 people.", language: "en") == "Book room 4 FOR 3 people.")
    }

    @Test func longerHumsAfterANumberAreStillHesitations() {
        #expect(Disfluency.strip("Il en reste 12 hmm je crois.", language: "fr") == "Il en reste 12 je crois.")
        #expect(Disfluency.strip("J'ai 3 umm questions.", language: "fr") == "J'ai 3 questions.")
    }

    @Test func listsKeepTheirCommas() {
        #expect(Disfluency.strip("x, euh, (euh), y", language: "fr") == "x, y")
        #expect(Disfluency.strip("5, euh, 6", language: "fr") == "5, 6")
    }

    @Test func lineBreaksSurvive() {
        #expect(Disfluency.strip("Courses :\neuh, du pain\net du lait") == "Courses :\nDu pain\net du lait")
    }
}
