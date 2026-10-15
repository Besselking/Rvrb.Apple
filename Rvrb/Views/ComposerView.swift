import SwiftUI

struct ComposerView: View {
    let client: RvrbClient

    @State private var text = ""
    @FocusState private var isFocused: Bool
    /// The highlighted suggestion.
    @State private var selectedSuggestion = 0
    /// Escape hid the suggestions for this text.
    @State private var suggestionsHiddenFor: String?

    private var canSend: Bool {
        client.channel != nil && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private enum Suggestions {
        case commands(prefix: Character, [BotCommand])
        case people([ChannelUser])

        var count: Int {
            switch self {
            case .commands(_, let commands): commands.count
            case .people(let users): users.count
            }
        }
    }

    /// Commands while a `/` or `!` command is being typed, people while an `@` name is.
    private var suggestions: Suggestions? {
        guard suggestionsHiddenFor != text else { return nil }

        if let query = CommandCompletion.query(in: text) {
            let matches = CommandCompletion.matches(query.partial, in: client.botCommands)
            return matches.isEmpty ? nil : .commands(prefix: query.prefix, matches)
        }
        if let query = MentionCompletion.query(in: text) {
            let matches = MentionCompletion.matches(query.partial, in: client.users, excluding: client.me.id)
            return matches.isEmpty ? nil : .people(matches)
        }
        return nil
    }

    private func selectedIndex(_ suggestions: Suggestions) -> Int {
        min(selectedSuggestion, suggestions.count - 1)
    }

    var body: some View {
        VStack(spacing: 0) {
            switch suggestions {
            case .commands(let prefix, let commands):
                SuggestionList(items: commands, selected: min(selectedSuggestion, commands.count - 1), onPick: complete) {
                    CommandRow(prefix: prefix, command: $0)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case .people(let users):
                SuggestionList(items: users, selected: min(selectedSuggestion, users.count - 1), onPick: mention) {
                    MentionRow(user: $0, avatarURL: client.avatarURL(for: $0.id))
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            case nil:
                EmptyView()
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
                    pick(suggestions)
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

    /// Replaces the partial `@name` with the person's display name, as the web app does.
    private func mention(_ user: ChannelUser) {
        guard let query = MentionCompletion.query(in: text) else { return }
        text = String(text[..<query.at]) + "@\(user.name) "
        isFocused = true
    }

    private func pick(_ suggestions: Suggestions) {
        switch suggestions {
        case .commands(_, let commands): complete(commands[selectedIndex(suggestions)])
        case .people(let users): mention(users[selectedIndex(suggestions)])
        }
    }

    private func moveSuggestion(by step: Int) -> KeyPress.Result {
        guard let suggestions else { return .ignored }
        let count = suggestions.count
        selectedSuggestion = (selectedIndex(suggestions) + step + count) % count
        return .handled
    }

    private func send() {
        // Return first picks the highlighted suggestion (as in the web app), unless it's already typed in full.
        if let suggestions {
            let typed: String?
            let picked: String
            switch suggestions {
            case .commands(_, let commands):
                typed = CommandCompletion.query(in: text)?.partial
                picked = commands[selectedIndex(suggestions)].name
            case .people(let users):
                typed = MentionCompletion.query(in: text)?.partial
                picked = users[selectedIndex(suggestions)].name
            }
            if typed?.lowercased() != picked.lowercased() {
                pick(suggestions)
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
