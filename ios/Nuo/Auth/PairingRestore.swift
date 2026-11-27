import Foundation
import Security

/// What the Keychain said about the device key, kept apart from the key itself so the decision is testable.
enum DeviceKeyLookup<Key: Sendable>: Sendable {
    case found(Key)
    case missing
    /// The Keychain refused to answer (locked iPhone, before the first unlock): the key may well be there.
    case unavailable(OSStatus)

    static func from(statuses: [OSStatus], found key: Key?) -> DeviceKeyLookup {
        if let key { return .found(key) }
        // An unsigned build lacks the private group: that answer says nothing about the key.
        let inconclusive: Set<OSStatus> = [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement]
        if let refusal = statuses.first(where: { !inconclusive.contains($0) }) { return .unavailable(refusal) }
        return .missing
    }
}

/// Whether a launch may show the pairing screen. Pairing again replaces the device key, so it is only offered when
/// the Keychain answered that there is no key, never when it could not be read.
enum PairingRestore<Key: Sendable>: Sendable {
    case paired(deviceId: String, key: Key)
    case unpaired
    case waitForUnlock

    /// `storedDeviceId` comes with the key in the Keychain; UserDefaults (`savedDeviceId`) can read empty while the
    /// key is there, and is only the fallback for keys stored before the id moved next to them.
    static func resolve(storedDeviceId: String? = nil, savedDeviceId: String?, key: DeviceKeyLookup<Key>) -> PairingRestore {
        let deviceId = storedDeviceId ?? savedDeviceId
        return switch key {
        case .unavailable: .waitForUnlock
        case .missing: .unpaired
        case let .found(key): deviceId.map { .paired(deviceId: $0, key: key) } ?? .unpaired
        }
    }
}
