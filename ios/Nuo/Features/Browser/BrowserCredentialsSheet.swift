import SwiftUI

/**
 « Se connecter »: the identifier and the password side by side, so the password manager fills the pair in one go.
 iOS only offers a saved pair when both fields are on screen together, and it cannot know which site the streamed
 page shows — hence the site name in the title, to look it up with.

 Nothing is kept: the fields are cleared as soon as they have been typed into the page, and the values never leave
 the device except as the keystrokes the user would have typed anyway.
 */
struct BrowserCredentialsSheet: View {
    let site: String
    /// Whether the page says a field has the keyboard; without one the keystrokes land wherever the page left it.
    let isEditing: Bool
    /// identifier, password, and whether to press Enter after them.
    let fill: (String, String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    private enum Field { case identifier, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Username or email", text: $identifier)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focus, equals: .identifier)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($focus, equals: .password)
                        .onSubmit { send(submit: true) }
                } header: {
                    Text(site.isEmpty ? String(localized: "Sign-in") : String(localized: "Sign-in to \(site)"))
                } footer: {
                    Text("Fill in both fields from your passwords: they are typed into the page as if you typed them, and nothing is kept here.")
                }
                .listRowBackground(Color.card)

                if !isEditing {
                    Section {
                        Label {
                            Text("No active field in the page. Tap the username field first, otherwise your password may end up in a visible field.")
                                .font(.callout)
                                .foregroundStyle(Color.ink)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.accent)
                        }
                    }
                    .listRowBackground(Color.card)
                }

                Section {
                    // Nothing is submitted blind: without a field to type into, Enter could send a half-filled form.
                    Button(isEditing ? "Fill in and submit" : "Fill in anyway") { send(submit: isEditing) }
                        .disabled(!canFill)
                    if isEditing {
                        Button("Fill in without submitting") { send(submit: false) }
                            .disabled(!canFill)
                    }
                }
                .listRowBackground(Color.card)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Sign In")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { close() }
                }
            }
        }
        .onAppear { focus = .identifier }
    }

    private var canFill: Bool { !identifier.isEmpty || !password.isEmpty }

    private func send(submit: Bool) {
        guard canFill else { return }
        fill(identifier, password, submit)
        close()
    }

    private func close() {
        identifier = ""
        password = ""
        dismiss()
    }
}
