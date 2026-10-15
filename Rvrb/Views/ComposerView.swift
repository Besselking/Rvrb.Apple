import SwiftUI

struct ComposerView: View {
    let client: RvrbClient

    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// The highlighted command suggestion.
    @State private var selectedSuggestion = 0
    /// Escape hid the suggestions for this text.
    @State private var suggestionsHiddenFor: String?

    private var canSend: Bool {
        client.channel != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The commands matching what's typed, while a `/` or `!` command is being typed.
    private var suggestions: (prefix: Character, commands: [BotCommand])? {
        guard suggestionsHiddenFor != text, let query = CommandCompletion.query(in: text) else { return nil }
        let matches = CommandCompletion.matches(query.partial, in: client.botCommands)
        return matches.isEmpty ? nil : (query.prefix, matches)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let suggestions {
                CommandSuggestions(prefix: suggestions.prefix, commands: suggestions.commands,
                                   selected: min(selectedSuggestion, suggestions.commands.count - 1),
                                   onPick: complete)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
        .animation(.snappy(duration: 0.15), value: suggestions == nil)
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
                    if suggestions != nil {
                        suggestionsHiddenFor = text
                        return .handled
                    }
                    guard client.replyingTo != nil else { return .ignored }
                    client.replyingTo = nil
                    return .handled
                }
                .onKeyPress(.tab) {
                    guard let suggestions else { return .ignored }
                    complete(suggestions.commands[min(selectedSuggestion, suggestions.commands.count - 1)])
                    return .handled
                }
                .onKeyPress(.upArrow) { moveSuggestion(by: -1) }
                .onKeyPress(.downArrow) { moveSuggestion(by: 1) }
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
            selectedSuggestion = 0
        }
    }

    /// Replaces the partial command with the picked one, ready for its arguments.
    private func complete(_ command: BotCommand) {
        guard let query = CommandCompletion.query(in: text) else { return }
        text = "\(String(query.prefix))\(command.name) "
        isFocused = true
    }

    private func moveSuggestion(by step: Int) -> KeyPress.Result {
        guard let suggestions else { return .ignored }
        let count = suggestions.commands.count
        selectedSuggestion = (min(selectedSuggestion, count - 1) + step + count) % count
        return .handled
    }

    private func send() {
        // Return first picks the highlighted command (as in the web app), unless it's already typed in full.
        if let suggestions, let query = CommandCompletion.query(in: text) {
            let command = suggestions.commands[min(selectedSuggestion, suggestions.commands.count - 1)]
            if command.name.lowercased() != query.partial.lowercased() {
                complete(command)
                return
            }
        }

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
