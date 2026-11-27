import Foundation

enum RecognizerFailure {
    /// kAFAssistantErrorDomain 1101/1107: no connection to the local recognizer; Cocoa 4097/4099: its XPC
    /// service died. Silences and timeouts (1110, 203…) are normal and only restart the request.
    static func isServiceFailure(_ error: Error) -> Bool {
        let error = error as NSError
        switch error.domain {
        case "kAFAssistantErrorDomain": return [1101, 1107].contains(error.code)
        case NSCocoaErrorDomain: return [4097, 4099].contains(error.code)
        default: return false
        }
    }
}
