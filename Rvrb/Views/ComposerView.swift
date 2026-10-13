import SwiftUI

struct ComposerView: View {
    let client: RvrbClient

    @State private var text = ""
    @FocusState private var isFocused: Bool

    private var canSend: Bool {
        client.channel != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField(client.channel == nil ? "Join a channel to chat" : "Message", text: $text)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.quaternary.opacity(0.6), in: Capsule())
                .focused($isFocused)
                .submitLabel(.send)
                .onSubmit(send)
                .disabled(client.channel == nil)

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
