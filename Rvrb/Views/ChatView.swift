import SwiftUI

/// The channel's chat. Follows new messages while scrolled to the bottom, and stays put when the user scrolled up.
struct ChatView: View {
    let client: RvrbClient

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    var body: some View {
        let messages = client.messages

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages.indices, id: \.self) { index in
                    let message = messages[index]
                    let userId = message.userId ?? ""
                    MessageRow(message: message,
                               showsHeader: showsHeader(messages, at: index),
                               avatarURL: client.avatarURL(for: userId, fallback: message.avatarURL),
                               activity: client.activity(of: userId),
                               isBot: message.kind == .bot || client.isBot(userId))
                        .id(message.id)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
        } action: { _, atBottom in
            isAtBottom = atBottom
        }
        .onChange(of: messages.last?.id) {
            if isAtBottom {
                position.scrollTo(edge: .bottom)
            }
        }
    }

    /// Consecutive messages from one person within a few minutes share a header.
    private func showsHeader(_ messages: [ChatMessage], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let message = messages[index], previous = messages[index - 1]
        return previous.userId != message.userId || previous.kind != message.kind
            || message.time.timeIntervalSince(previous.time) > 300
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let showsHeader: Bool
    let avatarURL: URL?
    var activity: UserActivity = .listening
    var isBot = false

    var body: some View {
        switch message.kind {
        case .notice, .alert:
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: message.kind == .alert ? "megaphone" : "info.circle")
                Text(message.body.text)
                    .textSelection(.enabled)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 4)

        case .play:
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                Text(message.body.text)
                    .lineLimit(2)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.secondary.opacity(0.08))

        case .chat, .whisper, .bot:
            HStack(alignment: .top, spacing: 10) {
                if showsHeader {
                    Avatar(name: message.name, url: avatarURL, seed: message.userId ?? message.name, activity: activity)
                } else {
                    Color.clear.frame(width: Avatar.size, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if showsHeader {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(Avatar.color(for: message.userId ?? message.name))
                            if isBot {
                                BotTag()
                            }
                            if message.kind == .whisper {
                                Text("whisper")
                                    .font(.caption2)
                                    .foregroundStyle(.purple)
                            }
                            Text(message.time, style: .time)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    if !message.body.plain.isEmpty {
                        Text(message.body.text)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    ForEach(message.body.images, id: \.self) { image in
                        ChatImageView(image: image)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.top, showsHeader ? 8 : 1)
            .padding(.bottom, 1)
            .background(background)
        }
    }

    private var background: Color {
        if message.mentionsMe { return .accentColor.opacity(0.14) }
        if message.kind == .whisper { return .purple.opacity(0.08) }
        return .clear
    }
}

/// A chat image in a box of fixed height: images load after the row is laid out, and a row that grew then would
/// shift everything below it while scrolling.
private struct ChatImageView: View {
    static let height: CGFloat = 180

    let image: ChatText.Image

    var body: some View {
        RemoteImage(source: image, maxPixelSize: 780, contentMode: .fit, upscales: false) { failed in
            if failed {
                Label("Image", systemImage: "photo").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 260, minHeight: Self.height, maxHeight: Self.height, alignment: .leading)
    }
}
