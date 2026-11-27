import Foundation
import Testing

/// The test bundle's Info.plist has none of the Nuo keys: the neutral values of a fresh clone apply.
struct AppIdentityTests {
    @Test func identifiersFallBackToTheNeutralBuild() {
        #expect(AppIdentity.identifier == "com.example.nuo")
        #expect(AppIdentity.appGroup == "group.com.example.nuo")
        #expect(AppIdentity.scoped("reminders.lock") == "com.example.nuo.reminders.lock")
    }

    @Test func storedGatewayWinsOverTheBuildDefault() {
        let url = AppIdentity.gatewayURL(stored: "https://nuo.example.com", configured: "https://192.0.2.10:8443")
        #expect(url.absoluteString == "https://nuo.example.com")
    }

    @Test func buildDefaultAppliesBeforeAnyPairing() {
        #expect(AppIdentity.gatewayURL(stored: nil, configured: "https://192.0.2.10:8443").host() == "192.0.2.10")
    }

    @Test func noGatewayAtAllGivesAnAddressThatNeverResolves() {
        #expect(AppIdentity.gatewayURL(stored: "", configured: "").host() == "gateway.invalid")
        #expect(AppIdentity.gatewayURL(stored: "nuo", configured: "").host() == "gateway.invalid")
    }
}
