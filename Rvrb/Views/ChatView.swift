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
                               activity: client.activity(of: userId))
                        .id(message.id)
                }
            }
            .padding(.vertical, 8)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
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

private struct ChatImageView: View {
    let image: ChatText.Image

    var body: some View {
        Group {
            switch image {
            case .url(let url):
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else if phase.error != nil {
                        Label("Image", systemImage: "photo").foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
            case .data(let data):
                if let image = PlatformImage(data: data) {
                    Image(platformImage: image).resizable().scaledToFit()
                }
            }
        }
        .frame(maxWidth: 260, maxHeight: 220, alignment: .leading)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
