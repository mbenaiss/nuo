import Foundation
import Testing

struct UserNamePreferenceTests {
    private let defaults = UserDefaults(suiteName: "UserNamePreferenceTests-\(UUID().uuidString)")!

    @Test func theDemoGreetsAlexEvenWhenTheDeviceSavedAnotherName() {
        defaults.set("Julie", forKey: UserNamePreference.key)
        #expect(UserNamePreference(defaults: defaults, isDemo: true).load() == "Alex")
    }

    @Test func theDemoLeavesTheSavedNameUntouched() {
        defaults.set("Julie", forKey: UserNamePreference.key)
        let demo = UserNamePreference(defaults: defaults, isDemo: true)
        demo.save("Camille")
        #expect(defaults.string(forKey: UserNamePreference.key) == "Julie")
        #expect(UserNamePreference(defaults: defaults, isDemo: false).load() == "Julie")
    }

    @Test func theRealAppKeepsTheNameTheUserTyped() {
        let preference = UserNamePreference(defaults: defaults, isDemo: false)
        #expect(preference.load() == "")
        preference.save("Julie")
        #expect(preference.load() == "Julie")
    }

    @Test func outsideTheDemoTheSharedPreferenceReadsTheDeviceName() {
        #expect(UserNamePreference.standard.defaults == .standard)
        #expect(!UserNamePreference.standard.isDemo)
    }
}
