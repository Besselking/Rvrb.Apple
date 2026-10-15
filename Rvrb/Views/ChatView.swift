import SwiftUI

/// The channel's chat. Follows new messages while scrolled to the bottom, and stays put when the user scrolled up.
struct ChatView: View {
    let client: RvrbClient
    var onSelectUser: (String) -> Void = { _ in }

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var isAtBottom = true

    var body: some View {
        // Muted people's messages are left out, as on the web.
        let muted = client.mutedUserIds
        let messages = muted.isEmpty ? client.messages : client.messages.filter { !muted.contains($0.userId ?? "") }
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
                               starred: client.hasStarred(userId),
                               isBot: message.kind == .bot || client.isBot(userId),
                               onSelectUser: client.hasProfile(userId) ? { onSelectUser(userId) } : nil,
                               repliedTo: message.replyTo.flatMap { bySyncTime[$0] },
                               onShowOriginal: { original in
                                   withAnimation { position.scrollTo(id: original.id, anchor: .center) }
                               })
                        .modifier(SwipeToReply(isEnabled: message.canReply && client.channel != nil) {
                            client.replyingTo = message
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
            #if os(iOS)
            .background(ScrollsToTopDisabled())
            #endif
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
    var starred = false
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
                    Avatar(name: message.name, url: avatarURL, seed: message.userId ?? message.name, activity: activity,
                           starred: starred)
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

/// Swipe a message to the left to answer it (iPhone): rightward swipes are the back gesture. The row follows the
/// finger, a reply arrow appears behind it, and letting go past the threshold starts the reply.
private struct SwipeToReply: ViewModifier {
    let isEnabled: Bool
    let action: () -> Void

    /// How far the row has moved left (positive).
    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 60

    func body(content: Content) -> some View {
        #if os(iOS)
        if isEnabled {
            content
                .offset(x: -offset)
                .background(alignment: .trailing) {
                    Image(systemName: "arrowshape.turn.up.left.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.tint)
                        .opacity(Double(min(offset / threshold, 1)))
                        .scaleEffect(offset >= threshold ? 1.1 : 0.8)
                        .animation(.snappy(duration: 0.15), value: offset >= threshold)
                        .padding(.trailing, 14)
                }
                .gesture(HorizontalSwipe { distance in
                    // Follows the finger up to the threshold, then resists.
                    let x = max(0, -distance)
                    offset = x <= threshold ? x : threshold + (x - threshold) * 0.25
                } onEnded: { _ in
                    if offset >= threshold { action() }
                    withAnimation(.snappy(duration: 0.25)) { offset = 0 }
                })
                .sensoryFeedback(.impact(weight: .medium), trigger: offset >= threshold) { old, new in new && !old }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// A pan that only starts on a leftward, mostly horizontal swipe, so the chat still scrolls and the back swipe
/// still goes back.
private struct HorizontalSwipe: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let distance = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .changed: onChanged(distance)
        case .ended, .cancelled, .failed: onEnded(distance)
        default: break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.5
        }
    }
}
#endif

#if os(iOS)
/// Turns off iOS's tap-the-top-to-scroll-up for the enclosing scroll view: a tap that just misses the channel's
/// name would otherwise send the chat back to its oldest message. SwiftUI has no modifier for it.
private struct ScrollsToTopDisabled: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) {}

    final class Finder: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            var view = superview
            while let current = view {
                if let scrollView = current as? UIScrollView {
                    scrollView.scrollsToTop = false
                    return
                }
                view = current.superview
            }
        }
    }
}
#endif
