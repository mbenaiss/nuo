import Foundation

/// `-demo`: recordings made on the watch at every stage, for screenshots without a watch or a gateway.
/// `-demoRecordings [list|note|transcript]` opens the screen directly.
enum RecordingsDemo {
    private static var arguments: [String] { ProcessInfo.processInfo.arguments }
    static var opensScreen: Bool { arguments.contains("-demo") && arguments.contains("-demoRecordings") }
    static var tab: String? {
        guard let index = arguments.firstIndex(of: "-demoRecordings"), index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-") else { return nil }
        return arguments[index + 1]
    }

    static let clientId = "3f6c2a1e-8d4b-4f0a-9c1e-5a7b2d9e4c10"

    static func recordings(now: Date = Date()) -> [PhoneRecording] {
        let calendar = Calendar.current
        let morning = calendar.date(bySettingHour: 10, minute: 2, second: 0, of: now) ?? now
        let lines: [RecordingLine] = [
            .init(start: 4, end: 11, text: String(localized: "Hi Julie, thanks for making the time. Shall we go over the Lyon trade show quote?"), speaker: "1"),
            .init(start: 12, end: 19, text: String(localized: "Sure, happy to. I went through the proposal with my business partner last night."), speaker: "2"),
            .init(start: 298, end: 309, text: String(localized: "The 24 m² booth works for us, but we'd like the corner spot to get two open sides."), speaker: "2"),
            .init(start: 309.5, end: 316, text: String(localized: "The corner is an extra €1,800, I can confirm it today."), speaker: "1"),
            .init(start: 742, end: 748.5, text: String(localized: "For the furniture, let's go with the option with the closed storage room."), speaker: "2"),
            .init(start: 749, end: 753.2, text: String(localized: "Great. We'll sign off on €12,000 before Friday."), speaker: "2"),
            .init(start: 754.5, end: 759, text: String(localized: "Perfect, I'll send you the purchase order tonight."), speaker: "1"),
            .init(start: 1190, end: 1199, text: String(localized: "You'll also need power for the booth, it's ordered separately from the organizer."), speaker: "1"),
            .init(start: 1494, end: 1503, text: String(localized: "One last thing: we'd like to set up the day before, on Wednesday, December 3."), speaker: "2"),
            .init(start: 1503.5, end: 1510, text: String(localized: "I'll check with the installer and get back to you by Monday."), speaker: "1"),
            .init(start: 1840, end: 1848, text: String(localized: "Thanks Julie, I'll send all of this by email."), speaker: "1"),
        ]
        // The view hides the section headed « Moments clés », the heading the note bot writes whatever the language.
        let note = String(localized: "demo.recordings.clientNote", defaultValue: """
            # Client call with Julie Martin: Lyon trade show quote
            **Date:** \(morning.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute())) · **Length:** 31 min · **Attendees:** Alex, Julie Martin (Atelier Martin)
            ## Summary
            Julie Martin approves the Lyon trade show quote: a 24 m² corner booth, furniture with a closed storage room, for €12,000 excl. VAT. The purchase order goes out tonight and the sign-off is due before Friday. Still open: power, ordered separately, and setup the day before the show.
            ## Moments clés
            - **[05:12]** “The corner is an extra €1,800, I can confirm it today.” The corner is accepted and goes into the final price.
            - **[12:34]** “We'll sign off on €12,000 before Friday.” Julie agrees on the budget, with a firm deadline.
            - **[25:01]** “We'd like to set up the day before, on Wednesday, December 3.” A scheduling constraint to confirm with the installer.
            ## Decisions
            - 24 m² corner booth, two open sides.
            - Furniture with a closed storage room.
            - Budget approved: €12,000 excl. VAT.
            ## Action items
            - [ ] Send the purchase order: **Alex**, due \(NoteFormat.day(morning))
            - [ ] Return the signed quote: **Julie Martin**, due \(NoteFormat.day(calendar.date(byAdding: .day, value: 6, to: morning) ?? morning))
            - [ ] Confirm the Wednesday, December 3 setup with the installer: **Alex**
            - [ ] Order power for the booth from the organizer: **unassigned**
            ## Takeaways
            - Atelier Martin is exhibiting in Lyon for the first time; Julie reviewed the proposal with her business partner.
            - Power is not included in the quote.
            ## Open questions
            - Is the installer available on Wednesday, December 3?
            """)
        var client = PhoneRecording(
            id: clientId, title: String(localized: "Client call with Julie Martin: Lyon trade show quote"), startedAt: morning, duration: 1862,
            markers: [RecordingMarker(id: "m1", offset: 312), RecordingMarker(id: "m2", offset: 754), RecordingMarker(id: "m3", offset: 1501)],
            template: .client, stage: .ready)
        client.lines = lines
        client.language = Locale.current.language.languageCode?.identifier == "fr" ? "fr" : "en"
        client.note = note
        client.speakerNames = ["1": "Alex", "2": "Julie Martin"]
        client.savedPath = "reunions/\(NoteFormat.day(morning))-" + String(localized: "demo.recordings.clientSlug", defaultValue: "client-call-julie-martin-lyon-trade-show-quote") + ".md"

        var doctor = PhoneRecording(
            id: "7a1d9e44-2b3c-4d5e-8f60-718293a4b5c6", title: String(localized: "Dr. Lefèvre appointment: right knee"),
            startedAt: now.addingTimeInterval(-25 * 60), duration: 1094,
            markers: [RecordingMarker(id: "d1", offset: 402), RecordingMarker(id: "d2", offset: 951)], template: .medical, stage: .transcribing)
        doctor.arrival.manifest = RecordingManifest(id: doctor.id, startedAt: doctor.startedAt, duration: 1094, markers: doctor.markers,
                                                    segmentCount: 37, isFinished: true)

        var ideas = PhoneRecording(
            id: "c58e0f12-9a7b-4c3d-b2e1-0f9e8d7c6b5a", title: String(localized: "Ideas for Nuo v2"), startedAt: now.addingTimeInterval(-6 * 60),
            duration: 352, markers: [RecordingMarker(id: "i1", offset: 128)], template: .ideas, stage: .transferring)
        ideas.arrival.manifest = RecordingManifest(id: ideas.id, startedAt: ideas.startedAt, duration: 352, markers: ideas.markers,
                                                   segmentCount: 12, isFinished: true)
        for index in 0..<7 { ideas.arrival.receive(index: index) }

        var lecture = PhoneRecording(
            id: "e2b4c6d8-1f3a-4b5c-9d7e-8f0a1b2c3d4e", title: String(localized: "Contract law lecture, session 6"),
            startedAt: calendar.date(byAdding: .day, value: -2, to: morning) ?? morning, duration: 5310,
            markers: [RecordingMarker(id: "l1", offset: 1220)], template: .lecture, stage: .ready)
        lecture.lines = [.init(start: 1215, end: 1226, text: String(localized: "Remember: relative nullity can only be invoked by the protected party."), speaker: "1")]
        lecture.note = String(localized: "demo.recordings.lectureNote", defaultValue: "# Contract law lecture, session 6\n## Summary\nRelative and absolute nullity, five-year limitation period.")
        return [ideas, doctor, client, lecture]
    }
}
