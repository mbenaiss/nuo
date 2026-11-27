import SwiftUI

/// Above the composer while Goal is on: what the bot will and will not do on its own.
struct GoalNotice: View {
    var body: some View {
        Label {
            Text("The bot sees it through without asking you at each step. It will still ask you to confirm sending an email, an invitation or a deletion. Stays on until you turn it off.")
        } icon: {
            Image(systemName: "scope")
        }
        .font(.footnote)
        .foregroundStyle(Color.text2)
        .padding(.horizontal, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}
