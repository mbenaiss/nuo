import Foundation

enum TranscriberError: LocalizedError {
    case unavailable, unsupportedLocale, assetsMissing, notAuthorized

    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Speech recognition is not available on this device.")
        case .unsupportedLocale: String(localized: "This language is not supported by speech recognition.")
        case .assetsMissing: String(localized: "The speech recognition model could not be downloaded.")
        case .notAuthorized: String(localized: "Allow speech recognition in Settings to talk to your bot.")
        }
    }
}
