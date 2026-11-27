import Foundation

extension MeetingFormat {
    static func longDate(_ date: Date) -> String { NoteFormat.longDate(date) }
    static func day(_ date: Date) -> String { NoteFormat.day(date) }
    static func slug(_ text: String) -> String { NoteFormat.slug(text) }
}

/// The prompt that turns the user's rough notes and the transcript into the meeting note.
enum MeetingPrompt {
    static func build(title: String, participants: String, startedAt: Date, duration: TimeInterval, notes: String,
                      transcript: MeetingTranscript, template: MeetingTemplate, userName: String) -> String {
        let me = userName.trimmingCharacters(in: .whitespaces).isEmpty ? "Moi" : userName
        let cleanNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotePrompt.compose(
            request: "Rédige le compte rendu de la réunion que je viens de terminer, à partir de mes notes et de sa transcription.",
            kindLabel: "Type de réunion",
            template: template,
            header: [
                "Titre prévu : \(title.isEmpty ? "(à déduire de la conversation)" : title)",
                "Date : \(MeetingFormat.longDate(startedAt)) · durée \(Int((duration / 60).rounded())) min",
                "Participants connus : \(participants.isEmpty ? "(à déduire de la conversation)" : participants)",
            ],
            rules: [
                NotePrompt.answerRule,
                NotePrompt.recognitionRule(speakers: "« \(me) » est moi (le micro), « Eux » regroupe les autres participants (le son de l'ordinateur), sans distinguer qui parle."),
                "Garde mes notes : chaque point que j'ai noté figure dans la note avec mes mots (corrige seulement les fautes de frappe), à l'endroit le plus pertinent, et dans mon ordre quand j'ai structuré mes notes avec des titres.",
                "Tout ce que tu ajoutes à partir de la transcription est en *italique*, pour qu'on le distingue de mes notes.",
                NotePrompt.noInventionRule,
                NotePrompt.dataRule(tags: ["mes_notes", "transcription"]),
            ],
            structure: NotePrompt.standardStructure(heading: "Titre de la réunion"),
            blocks: [
                .init(tag: "mes_notes", content: cleanNotes.isEmpty ? "(aucune note)" : cleanNotes),
                .init(tag: "transcription", content: transcript.plainText(meName: me)),
            ])
    }
}
