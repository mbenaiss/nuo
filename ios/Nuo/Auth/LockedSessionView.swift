import SwiftUI

/// Shown while the Keychain cannot be read yet (device still locked). Pairing is not offered here: the existing
/// pairing comes back on its own once the device is unlocked.
struct LockedSessionView: View {
    @Environment(SessionStore.self) private var session

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.largeTitle)
                .foregroundStyle(Color.text2)
            Text("Unlock the device to open Nuo.")
                .font(.body)
                .foregroundStyle(Color.ink)
                .multilineTextAlignment(.center)
            Button("Try Again") { session.restoreIfUnlocked() }
                .font(.subheadline.weight(.semibold))
                .tint(Color.accent)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}
