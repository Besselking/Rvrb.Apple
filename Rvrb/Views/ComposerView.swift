import SwiftUI

struct ComposerView: View {
    let client: RvrbClient

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        client.channel != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            if let reply = client.replyingTo {
                HStack(spacing: 10) {
                    ReplyQuote(original: reply, lineLimit: 1)
                    Spacer(minLength: 0)
                    Button {
                        client.replyingTo = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Cancel Reply")
                }
                .padding(.horizontal)
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            field
        }
        .animation(.snappy(duration: 0.2), value: client.replyingTo?.id)
        .onChange(of: client.replyingTo?.id) { _, id in
            guard id != nil else { return }
            // Picked from a message's menu: focus once the menu has gone, or the keyboard can fail to come up.
            Task {
                try? await Task.sleep(for: .milliseconds(350))
                isFocused = true
            }
        }
    }

    private var field: some View {
        HStack(spacing: 8) {
            TextField(client.channel == nil ? "Join a channel to chat" : (client.replyingTo == nil ? "Message" : "Reply"),
                      text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .onKeyPress(.escape) {
                    guard client.replyingTo != nil else { return .ignored }
                    client.replyingTo = nil
                    return .handled
                }
                .disabled(client.channel == nil)

            #if os(iOS)
            if isFocused {
                Button {
                    isFocused = false
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                        .font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Hide Keyboard")
                .transition(.opacity.combined(with: .scale))
            }
            #endif

            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title)
            }
            .buttonStyle(.borderless)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .animation(.snappy(duration: 0.2), value: isFocused)
        .onChange(of: text) { _, new in
            if new.count > client.chatMaxLength {
                text = String(new.prefix(client.chatMaxLength))
            }
        }
    }

    private func send() {
        guard canSend else { return }
        let message = text
        text = ""
        isFocused = true

        Task {
            // Put it back to try again, unless something new was typed meanwhile.
            if await !client.send(message), text.isEmpty {
                text = message
            }
        }
    }
}
