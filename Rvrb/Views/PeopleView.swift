import SwiftUI

/// The DJs in play order (the first is playing) and everyone else listening.
struct PeopleView: View {
    let client: RvrbClient
    /// A person was tapped (to show their profile).
    var onSelect: (String) -> Void = { _ in }

    #if os(iOS)
    @State private var editMode: EditMode = .inactive
    #endif

    var body: some View {
        List {
            djs
            listeners
        }
        #if os(macOS)
        .listStyle(.sidebar)
        #else
        .environment(\.editMode, $editMode)
        #endif
    }

    private var djs: some View {
        Section {
            if client.djIds.isEmpty {
                Text("No one is DJing")
                    .foregroundStyle(.secondary)
            }

            ForEach(Array(client.djIds.enumerated()), id: \.element) { index, id in
                Button { onSelect(id) } label: {
                    PersonRow(name: client.name(for: id), url: client.avatarURL(for: id), seed: id,
                              activity: client.activity(of: id), starred: client.hasStarred(id), isBot: client.isBot(id),
                              role: client.role(of: id),
                              detail: index == 0 ? "Playing" : "#\(index + 1)", isMe: id == client.me.id)
                }
                .buttonStyle(.plain)
                // The DJ playing now stays put.
                .moveDisabled(index == 0 || !client.isModerator)
            }
            .onMove(perform: moveHandler)

            if client.channel != nil {
                Button {
                    Task { await client.toggleDJ() }
                } label: {
                    Label(client.isDJ ? "Step Down" : "Step Up",
                          systemImage: client.isDJ ? "arrow.down.circle" : "arrow.up.circle")
                }
            }
        } header: {
            HStack {
                Text("DJs (\(client.djIds.count))")
                #if os(iOS)
                if client.isModerator && client.djIds.count > 2 {
                    Spacer()
                    Button(editMode.isEditing ? "Done" : "Reorder") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                }
                #endif
            }
        } footer: {
            #if os(macOS)
            if client.isModerator && client.djIds.count > 2 {
                Text("Drag the waiting DJs to reorder them.")
            }
            #endif
        }
    }

    private var listeners: some View {
        Section("Listeners (\(client.listeners.count))") {
            ForEach(client.listeners) { user in
                Button { onSelect(user.id) } label: {
                    PersonRow(name: user.name, url: client.avatarURL(for: user.id), seed: user.id,
                              activity: client.activity(of: user.id), starred: client.hasStarred(user.id),
                              isBot: user.isBot, role: client.role(of: user.id), detail: nil,
                              isMe: user.id == client.me.id)
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Moderators reorder the DJs by dragging.
    private var moveHandler: ((IndexSet, Int) -> Void)? {
        client.isModerator ? { offsets, destination in moveDJs(offsets, destination) } : nil
    }

    /// The DJs' new order, with the one playing kept first.
    private func moveDJs(_ offsets: IndexSet, _ destination: Int) {
        var order = client.djIds
        order.move(fromOffsets: offsets, toOffset: max(1, destination))
        guard order.first == client.djIds.first, order != client.djIds else { return }
        Task { await client.reorderDJs(order) }
    }
}

private struct PersonRow: View {
    let name: String
    let url: URL?
    let seed: String
    let activity: UserActivity
    let starred: Bool
    let isBot: Bool
    var role: ChannelRole? = nil
    let detail: String?
    let isMe: Bool

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: name, url: url, seed: seed, activity: activity, starred: starred, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .fontWeight(isMe ? .semibold : .regular)
                    .lineLimit(1)
                // The tags go under the name, so neither cuts the other off in a narrow column.
                if isBot || role != nil || isMe {
                    HStack(spacing: 6) {
                        if isBot {
                            BotTag()
                        }
                        if let role {
                            RoleTag(role: role)
                        }
                        if isMe {
                            Text("You")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .lineLimit(1)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

/// A channel role next to a name.
struct RoleTag: View {
    let role: ChannelRole

    var body: some View {
        Label(role.title, systemImage: role.systemImage)
            .labelStyle(.titleAndIcon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel(role.title)
    }

    private var color: Color {
        switch role {
        case .creator: .orange
        case .admin: .pink
        case .mod: .teal
        }
    }
}
