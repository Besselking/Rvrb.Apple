import SwiftUI

/// About the joined channel: its description and greeting (they often hold the room's rules), links, limits, and
/// the tracks played recently.
struct ChannelInfoView: View {
    let client: RvrbClient
    let channel: Channel

    @Environment(\.openURL) private var openURL
    @State private var fresh: Channel?
    @State private var history: [JSON] = []
    @State private var isLoading = true
    @State private var error: String?
    @State private var notice: String?

    /// The channel as just fetched, or as it was when joined.
    private var info: Channel { fresh ?? channel }

    var body: some View {
        List {
            Section {
                header
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            if let description = info.genre {
                Section("About") {
                    Text(ChatText.parse(.string(description)).text)
                        .textSelection(.enabled)
                }
            }

            if let greeting = info.greeting, greeting != info.genre {
                Section("Greeting") {
                    Text(ChatText.parse(.string(greeting)).text)
                        .textSelection(.enabled)
                }
            }

            if !links.isEmpty {
                Section("Links") {
                    ForEach(links, id: \.url) { link in
                        Button {
                            openURL(link.url)
                        } label: {
                            LabeledContent {
                                Image(systemName: "arrow.up.right").foregroundStyle(.tertiary)
                            } label: {
                                Label(link.title, systemImage: link.systemImage)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !details.isEmpty {
                Section("Details") {
                    ForEach(details, id: \.0) { name, value in
                        LabeledContent(name, value: value)
                    }
                }
            }

            Section {
                if let notice {
                    Label(notice, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }

                ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                    if let track = Track(entry["track"]) {
                        HistoryRow(track: track, entry: entry)
                            .contextMenu { actions(for: track) }
                            .swipeActions(edge: .trailing) { actions(for: track) }
                    }
                }

                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading history…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else if history.isEmpty {
                    Text("Nothing played yet.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Recently Played")
            }
        }
        .navigationTitle(info.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: channel.id) { await load() }
        .refreshable { await load() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            if let promo = info.promoImageURL {
                RemoteImage(url: promo, maxPixelSize: 900, contentMode: .fit) { failed in
                    // Room for it while loading; nothing if it can't be loaded.
                    if !failed {
                        ProgressView().frame(height: 120)
                    }
                }
                .frame(maxHeight: 160)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .onTapGesture { if let link = info.promoLink { openURL(link) } }
            }

            Text(info.title)
                .font(.title2.bold())
                .multilineTextAlignment(.center)

            if let slug = info.slug {
                Text("@\(slug)")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                Label("\(client.users.count) listening", systemImage: "person.2")
                if let followers = info.followerCount {
                    Label(followers == 1 ? "1 follower" : "\(followers) followers", systemImage: "heart")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            let following = client.isFollowing(info)
            Button {
                Task { await client.setFollowing(!following, info) }
            } label: {
                Label(following ? "Following" : "Follow", systemImage: following ? "heart.fill" : "heart")
                    .foregroundStyle(.white)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(following ? .pink : .accentColor)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func actions(for track: Track) -> some View {
        Button("Add to Queue", systemImage: "text.badge.plus") {
            Task { notice = await client.addToQueue([.track(id: track.id)]) }
        }
        .tint(.accentColor)

        if let link = SpotifyItem.track(id: track.id).link {
            Button("Open in Spotify", systemImage: "arrow.up.right.square") { openURL(link) }
        }
    }

    // MARK: Content

    private struct Link {
        let title: String
        let url: URL
        let systemImage: String
    }

    private var links: [Link] {
        var links: [Link] = []
        if let url = info.infoLink { links.append(Link(title: "More Info", url: url, systemImage: "info.circle")) }
        if let url = info.calendarLink { links.append(Link(title: "Calendar", url: url, systemImage: "calendar")) }
        return links
    }

    private var details: [(String, String)] {
        var details: [(String, String)] = []
        if let maxDJs = info.maxDJs { details.append(("DJs", "Up to \(maxDJs)")) }
        if let maxTurns = info.maxTurns, maxTurns > 0 {
            details.append(("Turns", maxTurns == 1 ? "1 track per turn" : "\(maxTurns) tracks per turn"))
        }
        if let created = info.created { details.append(("Created", created.formatted(date: .long, time: .omitted))) }
        return details
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }

        let id = channel.id
        async let loadedChannel = client.api.channel(id: id)
        async let loadedHistory = client.api.channelHistory(channelId: id)

        if let loaded = try? await loadedChannel { fresh = loaded }

        do {
            history = try await loadedHistory
            error = nil
        } catch {
            self.error = "Could not load the history: \(error.localizedDescription)"
        }
    }
}

private struct HistoryRow: View {
    let track: Track
    let entry: JSON

    var body: some View {
        HStack(spacing: 10) {
            Artwork(url: track.artworkURL(minWidth: 64), size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .lineLimit(1)
                Text(track.artists)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let dj = playedBy { Text(dj) }
                    if let time { Text("·"); Text(time, format: .relative(presentation: .named)) }
                    if entry["skipped"]?.bool == true {
                        Text("· skipped").foregroundStyle(.orange)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                let votes = Self.tally(entry["voteSummary"])
                if votes.dope > 0 { Label("\(votes.dope)", systemImage: "hand.thumbsup.fill").foregroundStyle(.green) }
                if votes.nope > 0 { Label("\(votes.nope)", systemImage: "hand.thumbsdown.fill").foregroundStyle(.red) }
                if votes.star > 0 { Label("\(votes.star)", systemImage: "star.fill").foregroundStyle(.yellow) }
            }
            .font(.caption2.monospacedDigit())
            .labelStyle(.titleAndIcon)
        }
    }

    private var playedBy: String? {
        let by = entry["playedBy"]
        return by?["displayName"]?.nonEmptyString ?? by?["userName"]?.nonEmptyString
    }

    private var time: Date? {
        entry["timestamp"]?.string.flatMap(Date.init(rvrb:))
    }

    /// Totals, or entries per voter like the live votes (`{ "<id>": { "dope": 1, … } }`).
    static func tally(_ summary: JSON?) -> (dope: Int, nope: Int, star: Int) {
        guard let summary else { return (0, 0, 0) }
        if summary["dope"]?.double != nil || summary["nope"]?.double != nil {
            return (summary["dope"]?.int ?? 0, summary["nope"]?.int ?? 0, summary["star"]?.int ?? 0)
        }
        var tally = (dope: 0, nope: 0, star: 0)
        for entry in summary.object?.values ?? [:].values {
            tally.dope += entry["dope"]?.isOn == true ? 1 : 0
            tally.nope += entry["nope"]?.isOn == true ? 1 : 0
            tally.star += entry["star"]?.isOn == true ? 1 : 0
        }
        return tally
    }
}
