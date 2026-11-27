import Foundation
import Testing

struct SecretKeyTests {
    @Test func namesFollowTheGatewayRule() {
        #expect(SecretKey.isValid("BANK_SECRET_KEY"))
        #expect(SecretKey.isValid("_NUO_CF_ACCESS_CLIENT_ID"))
        #expect(SecretKey.isValid("CF_vima"))
        #expect(!SecretKey.isValid("2FA_CODE"))
        #expect(!SecretKey.isValid("BANK-LOGIN"))
        #expect(!SecretKey.isValid("BANK LOGIN"))
        #expect(!SecretKey.isValid("CLÉ_API"))
        #expect(!SecretKey.isValid(""))
        #expect(!SecretKey.isValid(String(repeating: "A", count: 129)))
    }

    @Test func newFilesEndInEnvAtTheRootOrOneSubfolder() {
        #expect(SecretKey.isValidFileName("stripe.env"))
        #expect(SecretKey.isValidFileName("projects/merci-maitresse.env"))
        #expect(!SecretKey.isValidFileName("../stripe.env"))
        #expect(!SecretKey.isValidFileName(".stripe.env"))
        #expect(!SecretKey.isValidFileName("projects/billing/stripe.env"))
        #expect(!SecretKey.isValidFileName("stripe.txt"))
    }

    @Test func deleteQueryKeepsSlashesAndPlusSigns() throws {
        let path = SecretKey.deletePath(source: "projects/fitness+coach.env", key: "WHOOP_CLIENT_SECRET")
        let items = try #require(URLComponents(string: path)?.queryItems)
        #expect(path.hasPrefix("/api/secrets/entries?"))
        #expect(!path.contains("+"))
        #expect(items.first { $0.name == "source" }?.value == "projects/fitness+coach.env")
        #expect(items.first { $0.name == "key" }?.value == "WHOOP_CLIENT_SECRET")
    }
}
