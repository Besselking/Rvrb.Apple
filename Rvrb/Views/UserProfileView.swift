import SwiftUI

/// A user's public profile: picture, names, bio, social links, play statistics and achievements, and following.
struct UserProfileView: View {
    let client: RvrbClient
    let userId: String

    @Environment(\.openURL) private var openURL
    @State private var profile: JSON?
    @State private var statistics: JSON?
    @State private var achievements: [JSON] = []
    @State private var error: String?
    @State private var isChangingFollow = false

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

            if let bio = profile?["bio"]?.nonEmptyString {
                Section("Bio") {
                    Text(ChatText.parse(.string(bio)).text)
                        .textSelection(.enabled)
                }
            }

            if !socialLinks.isEmpty {
                Section("Elsewhere") {
                    ForEach(socialLinks, id: \.name) { link in
                        Button {
                            openURL(link.url)
                        } label: {
                            LabeledContent {
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(.tertiary)
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(link.name)
                                        Text(link.handle)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                } icon: {
                                    Image(systemName: link.systemImage)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if let statistics, statisticsAvailable(statistics) {
                Section("Plays") {
                    StatisticsRow(title: "This month", period: statistics["thismonth"])
                    StatisticsRow(title: "All time", period: statistics["alltime"])
                }
            }

            if !achievements.isEmpty {
                Section("Achievements (\(achievements.count))") {
                    ForEach(Array(achievements.enumerated()), id: \.offset) { _, achievement in
                        AchievementRow(achievement: achievement)
                    }
                }
            }
        }
        .navigationTitle(name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: userId) { await load() }
    }

    private var name: String {
        profile?["displayName"]?.nonEmptyString ?? client.user(userId)?.name ?? client.name(for: userId)
    }

    private var header: some View {
        VStack(spacing: 10) {
            Avatar(name: name, url: client.avatarURL(for: userId, fallback: RvrbAPI.imageURL(profile?["image"])),
                   seed: userId, activity: client.activity(of: userId), size: 96)

            VStack(spacing: 4) {
                HStack(spacing: 6) {
                    Text(name)
                        .font(.title2.bold())
                    if client.isBot(userId) || profile?["type"]?.string == "bot" {
                        BotTag()
                    }
                }
                .multilineTextAlignment(.center)

                if let userName = profile?["userName"]?.nonEmptyString ?? client.user(userId)?.userName {
                    Text("@\(userName)")
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 12) {
                    if let country = profile?["country"]?.nonEmptyString {
                        Label(Self.countryName(country), systemImage: "globe")
                    }
                    if let joined = joinedDate {
                        Label("Joined \(joined.formatted(.dateTime.month(.wide).year()))", systemImage: "calendar")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if userId != client.me.id && !(client.isBot(userId)) {
                followButton
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var followButton: some View {
        if let followed = client.followedUserIds {
            let following = followed.contains(userId)
            Button {
                isChangingFollow = true
                Task {
                    defer { isChangingFollow = false }
                    do {
                        try await client.setFollowingUser(!following, userId)
                    } catch {
                        self.error = "Could not \(following ? "unfollow" : "follow"): \(error.localizedDescription)"
                    }
                }
            } label: {
                Label(following ? "Following" : "Follow", systemImage: following ? "checkmark" : "plus")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .tint(following ? .secondary : .accentColor)
            .disabled(isChangingFollow)
        }
    }

    private var joinedDate: Date? {
        guard let text = (profile?["accountCreated"] ?? profile?["createdDate"])?.string else { return nil }
        // Mongo dates come with milliseconds; accept them without too.
        let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        return (try? Date(text, strategy: withFraction)) ?? (try? Date(text, strategy: .iso8601))
    }

    // MARK: Social links

    private struct SocialLink {
        let name: String
        let handle: String
        let url: URL
        let systemImage: String
    }

    /// Profile settings hold usernames or full links; only present when the user shows them.
    private var socialLinks: [SocialLink] {
        guard let settings = profile?["profileSettings"], settings["displaySocialSites"]?.bool != false else { return [] }

        let sites: [(key: String, name: String, base: String, systemImage: String)] = [
            ("lastfm", "Last.fm", "https://www.last.fm/user/", "music.note.list"),
            ("spotify", "Spotify", "https://open.spotify.com/user/", "music.note"),
            ("soundcloud", "SoundCloud", "https://soundcloud.com/", "cloud"),
            ("instagram", "Instagram", "https://instagram.com/", "camera"),
            ("twitter", "X", "https://x.com/", "at"),
        ]

        return sites.compactMap { site in
            guard var value = settings[site.key]?.nonEmptyString?.trimmingCharacters(in: .whitespaces), !value.isEmpty else {
                return nil
            }

            if value.hasPrefix("http://") || value.hasPrefix("https://") {
                guard let url = URL(string: value) else { return nil }
                let handle = url.pathComponents.last(where: { $0 != "/" }) ?? url.host() ?? value
                return SocialLink(name: site.name, handle: handle, url: url, systemImage: site.systemImage)
            }

            if value.hasPrefix("@") { value.removeFirst() }
            guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let url = URL(string: site.base + encoded) else { return nil }
            return SocialLink(name: site.name, handle: value, url: url, systemImage: site.systemImage)
        }
    }

    private func statisticsAvailable(_ statistics: JSON) -> Bool {
        ["thismonth", "alltime"].contains { statistics[$0]?.object?.isEmpty == false }
    }

    private static func countryName(_ code: String) -> String {
        Locale.current.localizedString(forRegionCode: code) ?? code
    }

    // MARK: Loading

    private func load() async {
        await client.loadFollowedUsers()

        async let profile = client.api.publicProfile(userId: userId)
        async let statistics = client.api.statistics(userId: userId)
        async let achievements = client.api.achievements(userId: userId)

        do {
            self.profile = try await profile
            error = nil
        } catch {
            self.error = "Could not load the profile: \(error.localizedDescription)"
        }

        // Extras: leave them out when they fail.
        self.statistics = try? await statistics
        self.achievements = (try? await achievements) ?? []
    }
}

private struct StatisticsRow: View {
    let title: String
    let period: JSON?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            HStack {
                stat("Dopes", "hand.thumbsup.fill", .green, period?["dopes"])
                stat("Nopes", "hand.thumbsdown.fill", .red, period?["nopes"])
                stat("Bookmarks", "star.fill", .yellow, period?["bookmarks"])
                stat("Score", "sparkles", .accentColor, period?["score"])
            }
        }
        .padding(.vertical, 2)
    }

    private func stat(_ name: String, _ systemImage: String, _ tint: Color, _ value: JSON?) -> some View {
        VStack(spacing: 2) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text((value?.double ?? 0).formatted(.number.precision(.fractionLength(0...1))))
                .font(.headline.monospacedDigit())
            Text(name)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct AchievementRow: View {
    let achievement: JSON

    var body: some View {
        HStack(spacing: 12) {
            icon
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(achievement["title"]?.nonEmptyString ?? achievement["name"]?.string ?? "Achievement")
                if let description = achievement["description"]?.nonEmptyString {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The icon is an image path or URL, or an emoji.
    @ViewBuilder
    private var icon: some View {
        let value = achievement["icon"]?.nonEmptyString
        if let value, value.contains("/") || value.contains("."), let url = RvrbAPI.imageURL(.string(value)) {
            RemoteImage(url: url, maxPixelSize: 108, contentMode: .fit) { _ in
                Image(systemName: "trophy.fill").foregroundStyle(.yellow)
            }
        } else if let value, value.count <= 4 {
            Text(value).font(.title2)
        } else {
            Image(systemName: "trophy.fill")
                .font(.title3)
                .foregroundStyle(.yellow)
        }
    }
}
