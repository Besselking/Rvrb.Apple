import SwiftUI

/// The DJs in play order (the first is playing) and everyone else listening.
struct PeopleView: View {
    let client: RvrbClient
    /// A person was tapped (to show their profile).
    var onSelect: (String) -> Void = { _ in }

    var body: some View {
        List {
            Section("DJs (\(client.djIds.count))") {
                if client.djIds.isEmpty {
                    Text("No one is DJing")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(client.djIds.enumerated()), id: \.element) { index, id in
                    Button { onSelect(id) } label: {
                        PersonRow(name: client.name(for: id), url: client.avatarURL(for: id), seed: id,
                                  activity: client.activity(of: id), isBot: client.isBot(id),
                                  detail: index == 0 ? "Playing" : "#\(index + 1)", isMe: id == client.me.id)
                    }
                    .buttonStyle(.plain)
                }

                if client.channel != nil {
                    Button {
                        Task { await client.toggleDJ() }
                    } label: {
                        Label(client.isDJ ? "Step Down" : "Step Up",
                              systemImage: client.isDJ ? "arrow.down.circle" : "arrow.up.circle")
                    }
                }
            }

            Section("Listeners (\(client.listeners.count))") {
                ForEach(client.listeners) { user in
                    Button { onSelect(user.id) } label: {
                        PersonRow(name: user.name, url: client.avatarURL(for: user.id), seed: user.id,
                                  activity: client.activity(of: user.id), isBot: user.isBot, detail: nil,
                                  isMe: user.id == client.me.id)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #endif
    }
}

private struct PersonRow: View {
    let name: String
    let url: URL?
    let seed: String
    let activity: UserActivity
    let isBot: Bool
    let detail: String?
    let isMe: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, url: url, seed: seed, activity: activity, size: 34)
            Text(name)
                .fontWeight(isMe ? .semibold : .regular)
                .lineLimit(1)
            if isBot {
                BotTag()
            }
            if isMe {
                Text("You")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}
