import SwiftUI

/// The channel's track: artwork, title, the DJ, progress, and the votes.
struct NowPlayingView: View {
    let client: RvrbClient
    var onSelectUser: (String) -> Void = { _ in }

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let playing = client.nowPlaying {
                HStack(alignment: .top, spacing: 12) {
                    Artwork(url: playing.track.artworkURL(minWidth: 160), size: 76)
                        .onTapGesture { openInSpotify(playing.track) }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel("Open \(playing.track.name) in Spotify")

                    VStack(alignment: .leading, spacing: 3) {
                        // The track and artist open it in Spotify.
                        VStack(alignment: .leading, spacing: 3) {
                            Text(playing.track.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(playing.track.artists)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { openInSpotify(playing.track) }
                        if let dj = client.djIds.first {
                            Label(dj == client.me.id ? "You're playing this" : client.name(for: dj), systemImage: "music.mic")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .onTapGesture { onSelectUser(dj) }
                        }

                        Spacer(minLength: 0)

                        progress(playing)
                    }
                }
                .frame(height: 76)
                .contextMenu { trackMenu(playing.track) }

                VoteBar(client: client, votes: playing.votes)
            } else {
                Label(client.channel == nil ? "Not in a channel" : "Nothing playing", systemImage: "music.note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }

            if client.isDJ {
                UpNext(client: client)
            }
        }
        .padding()
    }

    @ViewBuilder
    private func trackMenu(_ track: Track) -> some View {
        Button("Open in Spotify", systemImage: "arrow.up.right.square") { openInSpotify(track) }
        Button("Add to Queue", systemImage: "text.badge.plus") {
            Task { await client.addToQueue([.track(id: track.id)]) }
        }
        if let link = SpotifyItem.track(id: track.id).link {
            Button("Copy Link", systemImage: "link") { copy(link.absoluteString) }
        }
    }

    /// The Spotify app when it's there (its `spotify:` URI), otherwise the track's page on open.spotify.com.
    private func openInSpotify(_ track: Track) {
        let web = SpotifyItem.track(id: track.id).link
        guard let uri = track.uri.flatMap(URL.init(string:)) else {
            if let web { openURL(web) }
            return
        }
        // The completion runs off the main thread on the Mac: a closure tied to the main actor traps there.
        let openURL = openURL
        openURL(uri) { @Sendable opened in
            guard !opened, let web else { return }
            Task { @MainActor in openURL(web) }
        }
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    private func progress(_ playing: NowPlaying) -> some View {
        let range = playing.start...max(playing.end, playing.start)

        return VStack(spacing: 2) {
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            HStack {
                Text(timerInterval: range, countsDown: false)
                Spacer()
                Text(playing.track.duration.minutesAndSeconds)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }
}

private struct VoteBar: View {
    let client: RvrbClient
    let votes: Votes

    @State private var confirmsSkip = false

    var body: some View {
        // Voting on your own track fails with "Cannot vote for yourself".
        let disabled = client.isMyTurn

        HStack(spacing: 8) {
            votes(disabled: disabled)
            Spacer(minLength: 0)
            if client.canSkip {
                Button {
                    // Your own track skips at once; someone else's (as a moderator) asks first.
                    if client.isMyTurn {
                        Task { await client.skip() }
                    } else {
                        confirmsSkip = true
                    }
                } label: {
                    Label("Skip", systemImage: "forward.end.fill")
                }
                .buttonStyle(.bordered)
                .help(client.isMyTurn ? "Skip your track" : "Skip this DJ's track")
                .confirmationDialog("Skip \(client.djIds.first.map { client.name(for: $0) } ?? "the DJ")'s track?",
                                    isPresented: $confirmsSkip, titleVisibility: .visible) {
                    Button("Skip Track", role: .destructive) { Task { await client.skip() } }
                }
            }
        }
    }

    private func votes(disabled: Bool) -> some View {
        HStack(spacing: 8) {
            VoteButton(title: "Dope", systemImage: "hand.thumbsup", count: votes.dope, isOn: votes.mine.dope, tint: .green) {
                Task { await client.vote(.dope) }
            }
            VoteButton(title: "Nope", systemImage: "hand.thumbsdown", count: votes.nope, isOn: votes.mine.nope, tint: .red) {
                Task { await client.vote(.nope) }
            }
            VoteButton(title: "Star", systemImage: "star", count: votes.star, isOn: votes.mine.star, tint: .yellow) {
                Task { await client.vote(.star) }
            }
        }
        .disabled(disabled)
    }
}

private struct VoteButton: View {
    let title: String
    let systemImage: String
    let count: Int
    let isOn: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label {
                Text("\(count)").monospacedDigit()
            } icon: {
                Image(systemName: isOn ? systemImage + ".fill" : systemImage)
                    .foregroundStyle(isOn ? tint : .secondary)
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(.bordered)
        .tint(isOn ? tint : nil)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .help(isOn ? "Take back your \(title.lowercased())" : title)
    }
}

/// What this DJ plays on their next turn: the top of their queue.
private struct UpNext: View {
    let client: RvrbClient

    var body: some View {
        Group {
            if let next = client.queue.next {
                Label("Your next: \(next.name) — \(next.artists)", systemImage: "arrow.turn.down.right")
            } else if client.queue.isLoaded {
                Label("Your queue is empty: add tracks or you'll be taken off the decks.", systemImage: "exclamationmark.circle")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}
