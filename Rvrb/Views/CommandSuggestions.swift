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

/// The matching commands above the message box; the highlighted one is what Return or Tab picks.
struct CommandSuggestions: View {
    let prefix: Character
    let commands: [BotCommand]
    let selected: Int
    let onPick: (BotCommand) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                        Button {
                            onPick(command)
                        } label: {
                            row(command, isSelected: index == selected)
                        }
                        .buttonStyle(.plain)
                        .id(command.id)
                    }
                }
                .padding(4)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selected) { _, index in
                if commands.indices.contains(index) { proxy.scrollTo(commands[index].id) }
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    private func row(_ command: BotCommand, isSelected: Bool) -> some View {
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .accessibilityLabel("\(command.name). \(command.help ?? "")")
    }
}
