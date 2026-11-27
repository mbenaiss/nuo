import Testing

struct QuestionCardTests {
    private let pairing = QuestionPayload(
        question: "On commence par laquelle ?", options: ["Réappairer la télécommande", "Supprimer l'appareil"])
    private let rooms = QuestionPayload(question: "Quelles pièces ?", options: ["Salon", "Cuisine", "Chambre"], multiple: true)

    @Test func parsesAQuestionCard() {
        let text = """
        La télécommande du salon ne répond plus.
        ::question {"question":"On commence par laquelle ?","options":["Réappairer la télécommande","Supprimer l'appareil"],"multiple":false}
        """
        let blocks = ResponseBlockParser.parse(text)
        #expect(blocks == [.paragraph("La télécommande du salon ne répond plus."), .questions([pairing])])
    }

    @Test func multipleDefaultsToFalse() {
        let blocks = ResponseBlockParser.parse(#"::question {"question":"Tu pars quand ?","options":["Vendredi soir","Samedi matin"]}"#)
        #expect(blocks == [.questions([QuestionPayload(question: "Tu pars quand ?", options: ["Vendredi soir", "Samedi matin"])])])
    }

    @Test func consecutiveQuestionsMakeOneCard() {
        let text = """
        Deux questions avant de lancer le ménage :
        ::question {"question":"On commence par laquelle ?","options":["Réappairer la télécommande","Supprimer l'appareil"]}

        ::question {"question":"Quelles pièces ?","options":["Salon","Cuisine","Chambre"],"multiple":true}
        """
        let blocks = ResponseBlockParser.parse(text)
        #expect(blocks == [.paragraph("Deux questions avant de lancer le ménage :"), .questions([pairing, rooms])])
    }

    @Test func textBetweenQuestionsSplitsTheCards() {
        let text = """
        ::question {"question":"On commence par laquelle ?","options":["Réappairer la télécommande","Supprimer l'appareil"]}
        Ensuite, pour l'aspirateur :
        ::question {"question":"Quelles pièces ?","options":["Salon","Cuisine","Chambre"],"multiple":true}
        """
        let blocks = ResponseBlockParser.parse(text)
        #expect(blocks == [.questions([pairing]), .paragraph("Ensuite, pour l'aspirateur :"), .questions([rooms])])
    }

    @Test func acceptsCommonVariants() {
        let choices = ResponseBlockParser.parse(#"::question {"title":"Quelles pièces ?","choices":[{"label":"Salon"},{"text":"Cuisine"},"Chambre"],"multiple":"true"}"#)
        #expect(choices == [.questions([rooms])])

        let list = ResponseBlockParser.parse(#"::questions {"questions":[{"question":"On commence par laquelle ?","options":["Réappairer la télécommande","Supprimer l'appareil"]},{"question":"Quelles pièces ?","options":["Salon","Cuisine","Chambre"],"multi":true}]}"#)
        #expect(list == [.questions([pairing, rooms])])

        let spread = ResponseBlockParser.parse("""
        ::question
        {"question":"Quelles pièces ?",
         "options":["Salon","Cuisine","Chambre"],"multiple":true}
        """)
        #expect(spread == [.questions([rooms])])
    }

    @Test func invalidQuestionsStayPlainText() {
        let broken = #"::question {"question":"On commence par laquelle ?" "options":["Réappairer la télécommande","Supprimer l'appareil"]}"#
        #expect(ResponseBlockParser.parse(broken) == [.paragraph(broken)])

        let noOptions = #"::question {"question":"On commence par laquelle ?","options":[]}"#
        #expect(ResponseBlockParser.parse(noOptions) == [.paragraph(noOptions)])

        let noQuestion = #"::question {"options":["Salon","Cuisine"]}"#
        #expect(ResponseBlockParser.parse(noQuestion) == [.paragraph(noQuestion)])
    }

    @Test func aLoneAnswerReadsLikeATypedMessage() {
        let picked = QuestionReply.message(for: [pairing], answers: [QuestionAnswer(choices: ["Supprimer l'appareil"])])
        #expect(picked == "Supprimer l'appareil")

        let several = QuestionReply.message(for: [rooms], answers: [QuestionAnswer(choices: ["Salon", "Chambre"], other: "le couloir")])
        #expect(several == "Salon, Chambre, le couloir")

        let typed = QuestionReply.message(for: [pairing], answers: [QuestionAnswer(other: "Je l'ai déjà réappairée hier")])
        #expect(typed == "Je l'ai déjà réappairée hier")
    }

    @Test func aSeriesPutsEachQuestionBeforeItsAnswer() {
        let message = QuestionReply.message(
            for: [pairing, rooms],
            answers: [QuestionAnswer(choices: ["Réappairer la télécommande"]), QuestionAnswer(choices: ["Salon", "Cuisine"], other: "et l'entrée\nsi possible")])
        #expect(message == """
        On commence par laquelle ? → Réappairer la télécommande
        Quelles pièces ? → Salon, Cuisine, et l'entrée si possible
        """)
    }

    @Test func readsTheAnswersBackFromTheReply() {
        let series = "On commence par laquelle ? → Supprimer l'appareil\nQuelles pièces ? → Salon, Chambre"
        #expect(QuestionReply.answers(in: series, for: [pairing, rooms]) == [
            QuestionAnswer(choices: ["Supprimer l'appareil"]), QuestionAnswer(choices: ["Salon", "Chambre"]),
        ])

        let typed = "On commence par laquelle ? → Aucune, je rachète une télécommande"
        #expect(QuestionReply.answers(in: typed, for: [pairing, rooms]) == [QuestionAnswer(other: "Aucune, je rachète une télécommande"), nil])

        #expect(QuestionReply.answers(in: "supprimer l'appareil", for: [pairing]) == [QuestionAnswer(choices: ["Supprimer l'appareil"])])
        #expect(QuestionReply.answers(in: "Salon, Cuisine", for: [rooms]) == [QuestionAnswer(choices: ["Salon", "Cuisine"])])
        #expect(QuestionReply.answers(in: "Et la lumière du couloir ?", for: [pairing]) == [nil])
    }

    @Test func optionsHoldingACommaStillMatch() {
        let options = ["Oui, ce soir", "Oui", "Non"]
        #expect(QuestionReply.choices(in: "Oui, ce soir", options: options) == ["Oui, ce soir"])
        #expect(QuestionReply.choices(in: "Oui, Non", options: options) == ["Oui", "Non"])
        #expect(QuestionReply.choices(in: "Oui mais demain", options: options) == nil)
    }
}
