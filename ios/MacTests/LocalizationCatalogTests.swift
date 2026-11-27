import Foundation
import Testing

/// Localizable.xcstrings compiled into the test bundle: English keys, French translations.
struct LocalizationCatalogTests {
    private final class BundleToken {}

    private static func strings(_ language: String) throws -> Bundle {
        let path = try #require(Bundle(for: BundleToken.self).path(forResource: language, ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static func french(_ key: String) throws -> String {
        try strings("fr").localizedString(forKey: key, value: "\u{0}", table: nil)
    }

    @Test func googleAccountsScreenReadsInFrench() throws {
        #expect(try Self.french("Google Accounts") == "Comptes Google")
        #expect(try Self.french("Add a Google account") == "Ajouter un compte Google")
        #expect(try Self.french("Access revoked or expired: reconnect this account.") == "Accès révoqué ou expiré : reconnecte ce compte.")
    }

    @Test func frenchKeepsTheArgumentsInOrder() throws {
        let format = try Self.french("%@ connected (%@).")
        #expect(String(format: format, "julie.martin@example.com", "Gmail et Agenda") == "julie.martin@example.com connecté (Gmail et Agenda).")
    }

    /// Without en.lproj, iOS picks the only localization left and shows French on an English device.
    @Test func englishIsALocalizationOfItsOwn() throws {
        #expect(try Self.strings("en").localizedString(forKey: "Google Accounts", value: nil, table: nil) == "Google Accounts")
        #expect(Bundle(for: BundleToken.self).localizations.contains("en"))
    }

    @Test func everyKeyHasAFrenchText() throws {
        let url = try #require(Bundle(for: BundleToken.self).url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "fr"))
        let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
        #expect(!table.isEmpty)
        #expect(table.filter { $0.value.trimmingCharacters(in: .whitespaces).isEmpty }.isEmpty)
    }
}
