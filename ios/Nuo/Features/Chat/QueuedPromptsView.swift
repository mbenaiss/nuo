import SwiftUI

/// Messages waiting for the current answer to end; tapping one takes it back into the composer, « ↑ » sends it now.
struct QueuedPromptsView: View {
    let store: ConversationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(store.queued) { prompt in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "clock")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.text2)
                        .padding(.top, 2)
                    Button { store.editQueued(prompt.id) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if !prompt.text.isEmpty {
                                Text(prompt.text).lineLimit(2).foregroundStyle(Color.ink)
                            }
                            if !prompt.attachments.isEmpty {
                                Text("\(prompt.attachments.count) attachments")
                                    .foregroundStyle(Color.text2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!store.draft.isEmpty)
                    .help("Edit")
                    Button { withAnimation(.snappy) { store.sendNow(prompt.id) } } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.body).foregroundStyle(Color.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Send now")
                    .help("Send now, without waiting for the reply to finish")
                    Button { withAnimation(.snappy) { store.removeQueued(prompt.id) } } label: {
                        Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Color.text2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remove from queue")
                }
                .font(.footnote)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.chip, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            Text("Sent as soon as the reply finishes, or right away with ↑")
                .font(.caption2)
                .foregroundStyle(Color.text2)
                .padding(.leading, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Queued messages")
    }
}
