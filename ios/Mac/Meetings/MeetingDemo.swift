import Foundation

/// `-demo -demoScreen meeting|meetingnote`: a meeting in progress, or its generated note, without mic or bot.
enum MeetingDemo {
    struct Line {
        let speaker: MeetingSpeaker
        let start: TimeInterval
        let text: String
        var voice: String?
    }

    static let transcript: [Line] = [
        Line(speaker: .them, start: 4, text: String(localized: "demo.meeting.line1", defaultValue: "Um, hi, shall we start? I suggest we review the Mac release."), voice: "1"),
        Line(speaker: .me, start: 11, text: String(localized: "demo.meeting.line2", defaultValue: "Yes, on my side the reminders sync is done, only notifications are left.")),
        Line(speaker: .them, start: 22, text: String(localized: "demo.meeting.line3", defaultValue: "Great. On the design side, the menu bar panel mockups are ready, I'll send them to you tonight."), voice: "1"),
        Line(speaker: .me, start: 35, text: String(localized: "demo.meeting.line4", defaultValue: "Nice. We also need to set the beta date with the testers.")),
        Line(speaker: .them, start: 44, text: String(localized: "demo.meeting.line5", defaultValue: "We can aim for Friday the 24th. Hugo, can you prepare the tester list by Wednesday?"), voice: "1"),
        Line(speaker: .them, start: 52, text: String(localized: "demo.meeting.line6", defaultValue: "Hmm, yes, I'll send it Tuesday evening."), voice: "2"),
        Line(speaker: .me, start: 58, text: String(localized: "demo.meeting.line7", defaultValue: "I'll take care of the release notes and the help page.")),
        Line(speaker: .them, start: 612, text: String(localized: "demo.meeting.line8", defaultValue: "One last thing: do we open the beta to more people than the current list?"), voice: "2"),
        Line(speaker: .me, start: 621, text: String(localized: "demo.meeting.line9", defaultValue: "I'd rather stay at around thirty people for the first week, then we widen it.")),
        Line(speaker: .them, start: 838, text: String(localized: "demo.meeting.line10", defaultValue: "Works for me. Let's talk again Monday with the first feedback."), voice: "1"),
    ]

    static let notes = String(localized: "demo.meeting.notes", defaultValue: """
    ## Mac release
    - reminders ok, notifications left
    - menu bar mockups → Léa tonight
    - beta: Friday 24th?
    """)

    static let note = String(localized: "demo.meeting.note", defaultValue: """
    # Nuo weekly sync: Mac release
    **Date:** Monday, October 20, 2026 · **Duration:** 15 min · **Participants:** Léa Martin, Hugo Bernard, me
    
    ## Summary
    *The team reviewed the Mac release. The reminders sync is done and notifications still need to be finished. The beta is targeted for Friday, October 24.*
    
    ## Decisions
    - beta: Friday 24th *(confirmed in the meeting)*
    
    ## Actions
    - [ ] Send the menu bar panel mockups: **Léa**, due 2026-10-20
    - [ ] Prepare the beta tester list: **Hugo**, due 2026-10-22
    - [ ] Write the release notes and the help page: **Me**
    
    ## Key points
    ### Mac release
    - reminders ok, notifications left
    - menu bar mockups → Léa tonight
    - *The menu bar panel is ready on the design side.*
    
    ## Open questions
    - *Should the beta open to more testers than the current list?*
    """)
}
