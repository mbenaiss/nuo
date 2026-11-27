import Foundation
import Testing

struct AttachmentLimitsTests {
    private let limits = AttachmentLimits(maxCount: 4, maxFileBytes: 50_000_000, maxImageBytes: 100_000_000, maxEncodedBytes: 68_000_000)

    private func pdf(_ bytes: Int?) -> AttachmentCandidate {
        AttachmentCandidate(name: "devis-cuisine-2026.pdf", isDirectory: false, isReadable: true, byteCount: bytes, isImage: false)
    }

    @Test func base64GrowsByFourThirds() {
        #expect(AttachmentLimits.encodedSize(0) == 0)
        #expect(AttachmentLimits.encodedSize(1) == 4)
        #expect(AttachmentLimits.encodedSize(3) == 4)
        #expect(AttachmentLimits.encodedSize(30_000_000) == 40_000_000)
    }

    @Test func acceptsAFileUnderTheLimit() {
        #expect(limits.refusal(for: pdf(2_400_000), alreadyAttached: 1) == nil)
    }

    @Test func refusesAFileOverTheLimitBeforeReadingIt() {
        #expect(limits.refusal(for: pdf(64_000_000), alreadyAttached: 0) == .tooLarge(name: "devis-cuisine-2026.pdf", maxBytes: 50_000_000))
    }

    @Test func letsALargePhotoThroughSinceItIsReEncoded() {
        let photo = AttachmentCandidate(name: "IMG_4821.HEIC", isDirectory: false, isReadable: true, byteCount: 64_000_000, isImage: true)
        #expect(limits.refusal(for: photo, alreadyAttached: 0) == nil)
    }

    @Test func refusesAFolderAnUnreadableFileAndAFifthAttachment() {
        let folder = AttachmentCandidate(name: "Factures 2026", isDirectory: true, isReadable: true, byteCount: nil, isImage: false)
        let locked = AttachmentCandidate(name: "bulletin-salaire-mars.pdf", isDirectory: false, isReadable: false, byteCount: 180_000, isImage: false)
        #expect(limits.refusal(for: folder, alreadyAttached: 0) == .directory(name: "Factures 2026"))
        #expect(limits.refusal(for: locked, alreadyAttached: 0) == .unreadable(name: "bulletin-salaire-mars.pdf"))
        #expect(limits.refusal(for: pdf(120_000), alreadyAttached: 4) == .tooMany(max: 4))
    }

    @Test func refusesWhatWouldPushTheEncodedPromptOverTheGatewayLimit() {
        // Two 30 MB recordings encode to 80 MB, over what the gateway takes in one message.
        #expect(limits.refusal(adding: 30_000_000, named: "reunion-chantier.m4a", toAttached: [30_000_000])
            == .overBudget(name: "reunion-chantier.m4a", maxBytes: 68_000_000))
        #expect(limits.refusal(adding: 20_000_000, named: "plan-etage.pdf", toAttached: [30_000_000]) == nil)
    }

    @Test func explainsEachRefusal() {
        #expect(AttachmentRefusal.tooLarge(name: "devis-cuisine-2026.pdf", maxBytes: 50_000_000).message == "“devis-cuisine-2026.pdf” is over 50 MB.")
        #expect(AttachmentRefusal.tooMany(max: 4).message == "At most 4 attachments per message.")
    }

    @Test func inspectsTheFileSystemWithoutReadingTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Chantier-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let notes = folder.appendingPathComponent("compte-rendu.md")
        try "# Réunion de chantier\nLivraison des fenêtres le 12 novembre.".write(to: notes, atomically: true, encoding: .utf8)

        let file = AttachmentCandidate(url: notes)
        #expect(file.name == "compte-rendu.md")
        #expect(file.isDirectory == false && file.isReadable && file.isImage == false)
        let written = try Data(contentsOf: notes).count
        #expect(file.byteCount == written)
        #expect(AttachmentCandidate(url: folder).isDirectory)
        #expect(AttachmentCandidate(url: folder.appendingPathComponent("photo-facade.jpg")).isImage)
    }
}

struct ConversationStashTests {
    private struct Draft: Equatable {
        let text: String
        let queued: [String]
    }

    @Test func keysANewConversationByItsBot() {
        #expect(ConversationStash<Draft>.key(conversationId: nil, botId: "bot-compta") == "new-bot-compta")
        #expect(ConversationStash<Draft>.key(conversationId: "conv-8f2a", botId: "bot-compta") == "conv-8f2a")
    }

    @Test func givesBackTheDraftOnceWhenTheUserReturns() {
        var stash = ConversationStash<Draft>(capacity: 4)
        let draft = Draft(text: "Relance le fournisseur pour la facture FA-2026-0412", queued: ["Et prépare le virement"])
        stash.put(draft, for: "conv-8f2a")

        let first = stash.take("conv-8f2a")
        let second = stash.take("conv-8f2a")
        #expect(first == draft)
        #expect(second == nil)
    }

    @Test func dropsTheOldestDraftsBeyondItsCapacity() {
        var stash = ConversationStash<Draft>(capacity: 2)
        stash.put(Draft(text: "Devis cuisine", queued: []), for: "conv-1")
        stash.put(Draft(text: "Planning chantier", queued: []), for: "conv-2")
        stash.put(Draft(text: "Devis cuisine, version 2", queued: []), for: "conv-1")
        stash.put(Draft(text: "Note de frais", queued: []), for: "conv-3")

        #expect(stash.count == 2)
        let evicted = stash.take("conv-2")
        let rewritten = stash.take("conv-1")
        let latest = stash.take("conv-3")
        #expect(evicted == nil)
        #expect(rewritten?.text == "Devis cuisine, version 2")
        #expect(latest?.text == "Note de frais")
    }
}
