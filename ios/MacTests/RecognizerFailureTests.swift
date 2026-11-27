import Foundation
import Testing

struct RecognizerFailureTests {
    @Test func aCrashedOrUnreachableServiceStopsTheLiveRecognizer() {
        #expect(RecognizerFailure.isServiceFailure(NSError(domain: "kAFAssistantErrorDomain", code: 1101)))
        #expect(RecognizerFailure.isServiceFailure(NSError(domain: "kAFAssistantErrorDomain", code: 1107)))
        #expect(RecognizerFailure.isServiceFailure(NSError(domain: NSCocoaErrorDomain, code: 4097)))
        #expect(RecognizerFailure.isServiceFailure(NSError(domain: NSCocoaErrorDomain, code: 4099)))
    }

    @Test func silencesAndTimeoutsOnlyRestartTheRequest() {
        #expect(!RecognizerFailure.isServiceFailure(NSError(domain: "kAFAssistantErrorDomain", code: 1110)))
        #expect(!RecognizerFailure.isServiceFailure(NSError(domain: "kAFAssistantErrorDomain", code: 203)))
        #expect(!RecognizerFailure.isServiceFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)))
    }
}
