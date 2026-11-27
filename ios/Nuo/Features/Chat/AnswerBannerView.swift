import SwiftUI

/// Top banner announcing an answer from another conversation while the app is open.
struct AnswerBannerHost: View {
    @State private var notifier = AnswerNotifier.shared
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            if let banner = notifier.banner {
                AnswerBannerView(banner: banner)
                    .offset(y: min(0, drag))
                    .gesture(DragGesture()
                        .onChanged { drag = $0.translation.height }
                        .onEnded { value in
                            if value.translation.height < -30 { notifier.dismissBanner() }
                            drag = 0
                        })
                    .onTapGesture { notifier.openBanner() }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(banner.id)
            }
        }
        .padding(.horizontal, 12)
        .animation(.spring(response: 0.42, dampingFraction: 0.8), value: notifier.banner)
    }
}

struct AnswerBannerView: View {
    let banner: AnswerBanner

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            BotAvatar(emoji: banner.emoji, color: banner.color, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(banner.botName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                    Text("Reply ready")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.good)
                    Spacer(minLength: 0)
                    Text("now").font(.caption).foregroundStyle(Color.text3)
                }
                Text(banner.text)
                    .font(.subheadline)
                    .foregroundStyle(Color.text2)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        // Tinted glass: plain glass lets the chat header show through and the banner reads as clutter.
        .glassEffect(.regular.tint(Color.card.opacity(0.75)).interactive(), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the conversation")
    }
}
