import SwiftUI

/// Completing chat commands, as the web app does: a message starting with `/` or `!` lists the channel's commands
/// containing what's typed after it, the closest first.
enum CommandCompletion {
    /// The command being typed: the prefix and the partial name, while there's no space yet.
    static func query(in text: String) -> (prefix: Character, partial: String)? {
        guard let prefix = text.first, prefix == "/" || prefix == "!" else { return nil }
        let partial = text.dropFirst()
        guard !partial.contains(where: \.isWhitespace) else { return nil }
        return (prefix, String(partial))
    }

    static func matches(_ partial: String, in commands: [BotCommand]) -> [BotCommand] {
        let typed = partial.lowercased()
        guard !typed.isEmpty else { return commands.sorted { $0.name < $1.name } }

        return commands
            .filter { $0.name.lowercased().contains(typed) }
            .sorted { a, b in
                let (x, y) = (a.name.lowercased(), b.name.lowercased())
                let (xStarts, yStarts) = (x.hasPrefix(typed), y.hasPrefix(typed))
                if xStarts != yStarts { return xStarts }
                let (dx, dy) = (distance(x, typed), distance(y, typed))
                return dx != dy ? dx < dy : x < y
            }
    }

    /// Levenshtein distance, to rank the closest names first.
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }

        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}

/// Completing @mentions, as the web app does: an `@` at the end of the message (at its start or after a space)
/// lists the people in the channel whose display name or username contains what's typed after it.
enum MentionCompletion {
    /// Where the `@` is and the partial name after it, while there's no space yet.
    static func query(in text: String) -> (at: String.Index, partial: String)? {
        guard let at = text.lastIndex(of: "@") else { return nil }
        if at != text.startIndex, !text[text.index(before: at)].isWhitespace { return nil }
        let partial = text[text.index(after: at)...]
        guard !partial.contains(where: \.isWhitespace) else { return nil }
        return (at, String(partial))
    }

    static func matches(_ partial: String, in users: [ChannelUser], excluding me: String) -> [ChannelUser] {
        let typed = partial.lowercased()
        func names(_ user: ChannelUser) -> [String] { [user.name.lowercased(), user.userName?.lowercased() ?? ""] }

        return users
            .filter { $0.id != me && (typed.isEmpty || names($0).contains { $0.contains(typed) }) }
            .sorted { a, b in
                let (aStarts, bStarts) = (names(a).contains { $0.hasPrefix(typed) }, names(b).contains { $0.hasPrefix(typed) })
                if aStarts != bStarts { return aStarts }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
    }
}

/// Suggestions above the message box (commands or people); the highlighted one is what Return or Tab picks.
struct SuggestionList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    let selected: Int
    let onPick: (Item) -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            onPick(item)
                        } label: {
                            row(item)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(index == selected ? Color.accentColor.opacity(0.15) : .clear,
                                            in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(item.id)
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in
                if items.indices.contains(index) { proxy.scrollTo(items[index].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

struct CommandRow: View {
    let prefix: Character
    let command: BotCommand

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(String(prefix))\(command.name)")
                .font(.body.monospaced().weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            if let help = command.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MentionRow: View {
    let user: ChannelUser
    let avatarURL: URL?

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: user.name, url: avatarURL, seed: user.id, size: 26)
            Text(user.name)
                .lineLimit(1)
                .layoutPriority(1)
            if let userName = user.userName, userName != user.name {
                Text("@\(userName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if user.isBot { BotTag() }
        }
        .accessibilityElement(children: .combine)
    }
}
