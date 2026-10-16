import SwiftUI

/// The channel lists the web app has (popular, followed, the user's own, all), 16 per page with the most listeners
/// first, searchable. Searching Popular searches all channels: popular only has channels with someone in them.
struct ChannelListView: View {
    let client: RvrbClient
    @Binding var selection: Channel?

    @Environment(AppModel.self) private var model
    @AppStorage("channelList") private var list: RvrbAPI.ChannelList = .popular
    @State private var query = ""
    @State private var channels: [Channel] = []
    @State private var page = 0
    @State private var hasMore = false
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        List(selection: $selection) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            ForEach(channels) { channel in
                ChannelRow(channel: channel, isJoined: client.channel?.id == channel.id,
                           isFollowed: client.followedChannelIds.contains(channel.id))
                    .tag(channel)
                    .onAppear {
                        if channel == channels.last, hasMore, !isLoading {
                            Task { await load(reset: false) }
                        }
                    }
            }

            if isLoading && !channels.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .overlay {
            if channels.isEmpty {
                if isLoading {
                    ProgressView()
                } else if error == nil {
                    if !query.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        switch list {
                        case .popular:
                            ContentUnavailableView("No Busy Channels", systemImage: "music.note.house",
                                                   description: Text("Search to find a channel to join."))
                        case .followed:
                            ContentUnavailableView("No Followed Channels", systemImage: "heart",
                                                   description: Text("Follow a channel from its ⋯ menu to find it here."))
                        case .mine:
                            ContentUnavailableView("No Channels of Your Own", systemImage: "person.crop.square",
                                                   description: Text("Channels you created, administer or moderate show here."))
                        case .all:
                            ContentUnavailableView("No Channels", systemImage: "music.note.house")
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            Picker("Channels", selection: $list) {
                Text("Popular").tag(RvrbAPI.ChannelList.popular)
                Text("Following").tag(RvrbAPI.ChannelList.followed)
                Text("Mine").tag(RvrbAPI.ChannelList.mine)
                Text("All").tag(RvrbAPI.ChannelList.all)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .navigationTitle("Channels")
        #if os(macOS)
        // In the sidebar itself, so it collapses with it (the default is the window's toolbar).
        .searchable(text: $query, placement: .sidebar, prompt: "Search channels")
        #else
        .searchable(text: $query, prompt: "Search channels")
        #endif
        .task(id: "\(list.rawValue)|\(query)") {
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(350))
                if Task.isCancelled { return }
            }
            await load(reset: true)
        }
        .refreshable { await load(reset: true) }
        .toolbar {
            ToolbarItem {
                Menu {
                    Section("Logged in as \(client.me.name)") {
                        Button("Log Out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                            Task { await model.logOut() }
                        }
                    }
                } label: {
                    Label(client.me.name, systemImage: "person.crop.circle")
                }
            }
        }
    }

    private func load(reset: Bool) async {
        let search = query
        let list = list
        let next = reset ? 0 : page + 1
        isLoading = true
        defer { isLoading = false }

        do {
            let source: RvrbAPI.ChannelList = list == .popular && !search.isEmpty ? .all : list
            let result = try await client.api.channels(source, search: search, page: next)
            guard search == query, list == self.list else { return }
            if list == .followed && search.isEmpty {
                // Keep the room's Follow toggle in step with the list.
                if reset && !result.more { client.replaceFollowed(Set(result.channels.map(\.id))) }
            }

            if reset {
                channels = result.channels
            } else {
                let known = Set(channels.map(\.id))
                channels += result.channels.filter { !known.contains($0.id) }
            }
            page = next
            hasMore = result.more
            error = nil
        } catch is CancellationError {
        } catch let urlError as URLError where urlError.code == .cancelled {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct ChannelRow: View {
    let channel: Channel
    let isJoined: Bool
    let isFollowed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(channel.title)
                    .font(.headline)
                    .lineLimit(1)
                if isFollowed {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.pink)
                        .accessibilityLabel("Followed")
                }
                if isJoined {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.caption)
                        .foregroundStyle(.tint)
                        .accessibilityLabel("Joined")
                }
                Spacer(minLength: 4)
                Label("\(channel.listenerCount)", systemImage: "person.2.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(channel.listenerCount) listeners")
            }

            if let track = channel.nowPlaying {
                Label("\(track.name) — \(track.artists)", systemImage: "music.note")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let genre = channel.genre {
                Text(genre)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
