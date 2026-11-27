import Foundation
import Security
import Testing

struct PairingRestoreTests {
    private let julieDevice = "f3d5b352-e6a9-4ac3-b57f-3dbc70ac29eb"
    private let enclaveBlob = Data("secure-enclave-wrapped-p256".utf8)

    @Test func aLockedIPhoneWaitsInsteadOfAskingToPairAgain() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecInteractionNotAllowed, errSecInteractionNotAllowed], found: nil)
        let outcome = PairingRestore.resolve(savedDeviceId: julieDevice, key: lookup)
        guard case .waitForUnlock = outcome else { Issue.record("expected waitForUnlock, got \(outcome)"); return }
    }

    @Test func beforeTheFirstUnlockTheMissingDeviceIdDoesNotMeanUnpaired() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecInteractionNotAllowed, errSecItemNotFound], found: nil)
        let outcome = PairingRestore.resolve(savedDeviceId: nil, key: lookup)
        guard case .waitForUnlock = outcome else { Issue.record("expected waitForUnlock, got \(outcome)"); return }
    }

    @Test func aKeyStoredInTheDefaultGroupStillRestoresThePairing() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecItemNotFound, errSecSuccess], found: enclaveBlob)
        let outcome = PairingRestore.resolve(savedDeviceId: julieDevice, key: lookup)
        guard case let .paired(deviceId, key) = outcome else { Issue.record("expected paired, got \(outcome)"); return }
        #expect(deviceId == julieDevice)
        #expect(key == enclaveBlob)
    }

    @Test func pairingIsOfferedOnlyWhenTheKeychainSaysThereIsNoKey() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecItemNotFound, errSecItemNotFound], found: nil)
        let outcome = PairingRestore.resolve(savedDeviceId: julieDevice, key: lookup)
        guard case .unpaired = outcome else { Issue.record("expected unpaired, got \(outcome)"); return }
    }

    @Test func anUnsignedBuildWithoutThePrivateGroupIsNotMistakenForALockedDevice() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecMissingEntitlement, errSecItemNotFound], found: nil)
        guard case .missing = lookup else { Issue.record("expected missing, got \(lookup)"); return }
    }

    @Test func anUnexpectedKeychainErrorNeverLeadsToPairing() {
        let lookup = DeviceKeyLookup<Data>.from(statuses: [errSecItemNotFound, errSecDecode], found: nil)
        let outcome = PairingRestore.resolve(savedDeviceId: julieDevice, key: lookup)
        guard case .waitForUnlock = outcome else { Issue.record("expected waitForUnlock, got \(outcome)"); return }
    }

    @Test func theIdKeptWithTheKeyRestoresThePairingWhenUserDefaultsReadEmpty() {
        let outcome = PairingRestore.resolve(storedDeviceId: julieDevice, savedDeviceId: nil, key: DeviceKeyLookup<Data>.found(enclaveBlob))
        guard case let .paired(deviceId, _) = outcome else { Issue.record("expected paired, got \(outcome)"); return }
        #expect(deviceId == julieDevice)
    }

    @Test func aKeyWithoutAnyDeviceIdIsAnUnfinishedPairing() {
        let outcome = PairingRestore.resolve(savedDeviceId: nil, key: DeviceKeyLookup<Data>.found(enclaveBlob))
        guard case .unpaired = outcome else { Issue.record("expected unpaired, got \(outcome)"); return }
    }
}
