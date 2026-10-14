import SwiftUI

/// The channel's chat. Follows new messages while scrolled to the bottom, and stays put when the user scrolled up.
struct ChatView: View {
    let client: RvrbClient
    var onSelectUser: (String) -> Void = { _ in }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    var body: some View {
        let messages = client.messages
        // Replies name the answered message by its syncTime.
        let bySyncTime = Dictionary(messages.compactMap { message in message.syncTime.map { ($0, message) } },
                                    uniquingKeysWith: { first, _ in first })

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(messages.indices, id: \.self) { index in
                    let message = messages[index]
                    let userId = message.userId ?? ""
                    MessageRow(message: message,
                               showsHeader: showsHeader(messages, at: index),
                               avatarURL: client.avatarURL(for: userId, fallback: message.avatarURL),
                               activity: client.activity(of: userId),
                               isBot: message.kind == .bot || client.isBot(userId),
                               onSelectUser: client.hasProfile(userId) ? { onSelectUser(userId) } : nil,
                               repliedTo: message.replyTo.flatMap { bySyncTime[$0] },
                               onShowOriginal: { original in
                                   withAnimation { position.scrollTo(id: original.id, anchor: .center) }
                               })
                        .id(message.id)
                        .contextMenu {
                            if message.canReply && client.channel != nil {
                                Button("Reply", systemImage: "arrowshape.turn.up.left") {
                                    client.replyingTo = message
                                }
                            }
                            if !message.body.plain.isEmpty {
                                Button("Copy", systemImage: "doc.on.doc") {
                                    copyToPasteboard(message.body.plain)
                                }
                            }
                        }
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

    /// Consecutive messages from one person within a few minutes share a header; a reply starts its own.
    private func showsHeader(_ messages: [ChatMessage], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let message = messages[index], previous = messages[index - 1]
        return previous.userId != message.userId || previous.kind != message.kind
            || message.time.timeIntervalSince(previous.time) > 300 || message.replyTo != nil
    }

    private func copyToPasteboard(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }
}

struct MessageRow: View {
    let message: ChatMessage
    let showsHeader: Bool
    let avatarURL: URL?
    var activity: UserActivity = .listening
    var isBot = false
    /// Tapping the avatar or name shows the sender's profile.
    var onSelectUser: (() -> Void)? = nil
    /// The message this one answers, when it's still loaded.
    var repliedTo: ChatMessage? = nil
    var onShowOriginal: (ChatMessage) -> Void = { _ in }

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
                        .onTapGesture { onSelectUser?() }
                } else {
                    Color.clear.frame(width: Avatar.size, height: 1)
                }

                VStack(alignment: .leading, spacing: 2) {
                    if showsHeader {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(message.name)
                                .font(.subheadline.bold())
                                .foregroundStyle(Avatar.color(for: message.userId ?? message.name))
                                .onTapGesture { onSelectUser?() }
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

                    if message.replyTo != nil {
                        ReplyQuote(original: repliedTo)
                            .onTapGesture { if let repliedTo { onShowOriginal(repliedTo) } }
                    }

                    if !message.body.plain.isEmpty {
                        Text(message.body.text)
                            #if os(macOS)
                            // On iPhone a long press opens the Reply/Copy menu instead.
                            .textSelection(.enabled)
                            #endif
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

/// The answered message, quoted above a reply: who wrote it and how it started.
struct ReplyQuote: View {
    let original: ChatMessage?
    var lineLimit = 2

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tint)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Label(original?.name ?? "An earlier message", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(original.map { Avatar.color(for: $0.userId ?? $0.name) } ?? .secondary)
                if let original {
                    Text(original.body.plain.isEmpty ? "Image" : original.body.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(lineLimit)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(original.map { "Reply to \($0.name): \($0.body.plain)" } ?? "Reply to an earlier message")
    }
}
