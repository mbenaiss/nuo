import SwiftUI

extension View {
    /// Keyboard hints for one-time codes; only the content type exists on macOS.
    func oneTimeCodeInput(numeric: Bool) -> some View {
        #if os(iOS)
        self.keyboardType(numeric ? .numberPad : .asciiCapable)
            .textContentType(.oneTimeCode)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self.textContentType(.oneTimeCode).autocorrectionDisabled()
        #endif
    }

    func urlInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
        #else
        self.autocorrectionDisabled()
        #endif
    }

    /// Free text typed exactly as given on the gateway: no capitalization, correction or autofill suggestions.
    func plainIdentifierInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(nil)
        #else
        self.autocorrectionDisabled()
        #endif
    }
}
