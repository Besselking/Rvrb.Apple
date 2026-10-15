import SwiftUI

/// The joined channel: now playing with votes, the chat, and the message box. People are in an inspector (a
/// sheet on iPhone, presented through the one `sheet(item:)`: two presenters on one view fight each other); the
/// queue, track search and Spotify device in sheets.
struct RoomView: View {
    let client: RvrbClient

    #if os(macOS)
    @State private var showsPeople = true
    #else
    @State private var showsPeople = false
    #endif
    @State private var sheet: Sheet?
    @State private var isDropTargeted = false
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    /// iPad and Mac show people beside the chat; iPhone in a sheet.
    private var peopleInSheet: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    enum Sheet: Identifiable, Hashable {
        case queue, search, devices, people, info
        case profile(userId: String)

        var id: String {
            switch self {
            case .queue: "queue"
            case .search: "search"
            case .devices: "devices"
            case .people: "people"
            case .info: "info"
            case .profile(let userId): "profile-\(userId)"
            }
        }
    }

    private func showProfile(_ userId: String) {
        guard client.hasProfile(userId) else { return }
        sheet = .profile(userId: userId)
    }

    private var title: String {
        client.channel?.title ?? client.joining?.title ?? "Channel"
    }

    var body: some View {
        VStack(spacing: 0) {
            ConnectionBanner(client: client)
            NowPlayingView(client: client, onSelectUser: showProfile)
            Divider()

            if client.channel == nil && client.joining != nil {
                ProgressView("Joining \(title)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ChatView(client: client, onSelectUser: showProfile)
            }

            ComposerView(client: client)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    .overlay {
                        Label("Add to your queue", systemImage: "text.badge.plus")
                            .font(.title3.bold())
                            .padding()
                            .background(.regularMaterial, in: Capsule())
                    }
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        // Spotify tracks or playlists dropped on the room go to the bottom of the queue.
        .dropDestination(for: SpotifyDrop.self) { drops, _ in
            let items = SpotifyDrop.items(in: drops)
            guard !items.isEmpty else { return false }
            Task { await client.addToQueue(items) }
            return true
        } isTargeted: { targeted in
            isDropTargeted = targeted
        }
        .navigationTitle(title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar { toolbar }
        .inspector(isPresented: peopleInSheet ? .constant(false) : $showsPeople) {
            PeopleView(client: client, onSelect: showProfile)
                .inspectorColumnWidth(min: 200, ideal: 240, max: 340)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .queue: QueueView(client: client)
            case .search: SearchSheet(client: client)
            case .devices: DevicesView(client: client)
            case .people: PeopleSheet(client: client)
            case .profile(let userId): ProfileSheet(client: client, userId: userId)
            case .info:
                if let channel = client.channel { ChannelInfoSheet(client: client, channel: channel) }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        #if os(iOS)
        // The channel's name opens its info (description, rules, history).
        ToolbarItem(placement: .principal) {
            Button {
                sheet = .info
            } label: {
                VStack(spacing: 0) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)
                    if client.channel != nil {
                        Text("Channel info")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(client.channel == nil)
            .accessibilityHint("Shows the channel's description and play history")
        }
        #else
        ToolbarItem(placement: .navigation) {
            Button {
                sheet = .info
            } label: {
                Label("Channel Info", systemImage: "info.circle")
            }
            .help("The channel's description, rules and play history")
            .disabled(client.channel == nil)
        }
        #endif

        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await client.toggleDJ() }
            } label: {
                Label(client.isDJ ? "Step Down" : "Step Up",
                      systemImage: client.isDJ ? "arrow.down.circle.fill" : "arrow.up.circle")
            }
            .help(client.isDJ ? "Leave the decks" : "Join the decks and play from your queue")
            .disabled(client.channel == nil)

            Button {
                sheet = .queue
            } label: {
                Label("Queue", systemImage: "list.bullet")
            }
            .help("Your DJ queue")

            Button {
                if peopleInSheet {
                    sheet = .people
                } else {
                    showsPeople.toggle()
                }
            } label: {
                Label("People", systemImage: "person.2")
            }
            .help("DJs and listeners")

            Menu {
                Button("Channel Info…", systemImage: "info.circle") { sheet = .info }
                    .disabled(client.channel == nil)
                Button("Add Tracks…", systemImage: "plus") { sheet = .search }
                Button("Spotify Device…", systemImage: "hifispeaker") { sheet = .devices }

                Toggle(isOn: Binding(get: { client.player.isEnabled },
                                     set: { enabled in Task { await client.player.setEnabled(enabled) } })) {
                    Label("Play on Spotify", systemImage: "play.circle")
                }

                if let channel = client.channel {
                    Toggle(isOn: Binding(get: { client.isFollowing(channel) },
                                         set: { follow in Task { await client.setFollowing(follow, channel) } })) {
                        Label("Follow Channel", systemImage: "heart")
                    }
                }

                #if os(iOS)
                Toggle(isOn: Binding(get: { client.liveActivity.isEnabled },
                                     set: { client.liveActivity.isEnabled = $0 })) {
                    Label("Live Activity", systemImage: "platter.filled.top.iphone")
                }
                #endif

                Button("Resync Playback", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await client.player.resync() }
                }
                .disabled(client.nowPlaying == nil || !client.player.isEnabled)

                Divider()

                Button("Leave Channel", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                    Task { await client.leave() }
                }
                .disabled(client.channel == nil)
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
        }
    }
}

/// Shown while the websocket isn't connected.
private struct ConnectionBanner: View {
    let client: RvrbClient

    var body: some View {
        let status = client.socket.status

        if status != .connected {
            HStack {
                if status == .connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                }
                Text(status.label)
                    .lineLimit(2)
                Spacer()
                if status != .connecting {
                    Button("Reconnect") { client.socket.start() }
                        .buttonStyle(.borderless)
                }
            }
            .font(.callout)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.orange.opacity(0.15))
        }
    }
}

struct SearchSheet: View {
    let client: RvrbClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SearchView(client: client)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #else
                .sheetBar { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }
}

extension View {
    /// A bottom bar of buttons for Mac sheets, which have no toolbar.
    func sheetBar<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Spacer()
                    content()
                }
                .padding(12)
            }
            .background(.bar)
        }
    }
}

private struct PeopleSheet: View {
    let client: RvrbClient
    @Environment(\.dismiss) private var dismiss
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            PeopleView(client: client) { userId in
                if client.hasProfile(userId) { selected = userId }
            }
                .navigationDestination(item: $selected) { userId in
                    UserProfileView(client: client, userId: userId)
                }
                .navigationTitle("People")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct ProfileSheet: View {
    let client: RvrbClient
    let userId: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            UserProfileView(client: client, userId: userId)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #else
                .sheetBar { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #else
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }
}

private struct ChannelInfoSheet: View {
    let client: RvrbClient
    let channel: Channel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChannelInfoView(client: client, channel: channel)
                #if os(iOS)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                #else
                .sheetBar { Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }
}
