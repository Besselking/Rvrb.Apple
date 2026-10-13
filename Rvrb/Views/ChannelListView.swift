import SwiftUI

/// Popular channels (16 per page, most listeners first), or all channels matching a search.
struct ChannelListView: View {
    let client: RvrbClient
    @Binding var selection: Channel?

    @Environment(AppModel.self) private var model
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
                ChannelRow(channel: channel, isJoined: client.channel?.id == channel.id)
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
                    if query.isEmpty {
                        ContentUnavailableView("No Busy Channels", systemImage: "music.note.house",
                                               description: Text("Search to find a channel to join."))
                    } else {
                        ContentUnavailableView.search(text: query)
                    }
                }
            }
        }
        .navigationTitle("Channels")
        .searchable(text: $query, prompt: "Search channels")
        .task(id: query) {
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
        let next = reset ? 0 : page + 1
        isLoading = true
        defer { isLoading = false }

        do {
            let result = try await client.api.channels(search: search, page: next)
            guard search == query else { return }

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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(channel.title)
                    .font(.headline)
                    .lineLimit(1)
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
