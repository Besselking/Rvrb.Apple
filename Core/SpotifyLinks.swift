import Foundation

/// A Spotify item found in dropped or shared text.
nonisolated enum SpotifyItem: Hashable, Sendable {
    case track(id: String)
    case playlist(id: String)
    /// Not something the queue takes (albums, artists, episodes…), kept to say so.
    case unsupported(kind: String)

    var link: URL? {
        switch self {
        case .track(let id): URL(string: "https://open.spotify.com/track/\(id)")
        case .playlist(let id): URL(string: "https://open.spotify.com/playlist/\(id)")
        case .unsupported: nil
        }
    }
}

/// Finds Spotify links (`https://open.spotify.com/track/…`, `spotify:track:…`) in text: what Spotify puts on the
/// pasteboard when dragging or sharing tracks, one per line for several.
nonisolated enum SpotifyLinks {
    static func items(in text: String) -> [SpotifyItem] {
        var items: [SpotifyItem] = []
        var seen = Set<SpotifyItem>()

        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let kindRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 2), in: text) else { continue }

            let kind = text[kindRange].lowercased()
            let id = String(text[idRange])
            let item: SpotifyItem = switch kind {
            case "track": .track(id: id)
            case "playlist": .playlist(id: id)
            default: .unsupported(kind: kind)
            }

            if seen.insert(item).inserted { items.append(item) }
        }
        return items
    }

    private static let pattern = try! NSRegularExpression(
        pattern: #"(?:spotify:|open\.spotify\.com/(?:intl-[a-z-]+/)?(?:embed/)?)(track|playlist|album|artist|episode|show)[:/]([A-Za-z0-9]{22})"#,
        options: [.caseInsensitive])
}

/// Spotify's public oEmbed endpoint: a title and artwork for a link, without logging in.
nonisolated struct SpotifyPreview: Sendable, Hashable {
    var title: String
    var thumbnail: URL?

    static func load(_ link: URL) async -> SpotifyPreview? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: link.absoluteString)]

        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let json = try? JSON(parsing: data),
              let title = json["title"]?.nonEmptyString else { return nil }

        return SpotifyPreview(title: title, thumbnail: json["thumbnail_url"]?.string.flatMap(URL.init(string:)))
    }
}

extension RvrbAPI {
    /// The id of the user's DJ queue: the stack marked `activeQueue`, created when there is none.
    func djQueueId() async throws -> String {
        let stacks = try await stacks()
        let queue = stacks.first { $0["activeQueue"]?.bool == true && $0["deleted"]?.bool != true }
        let stack = if let queue { queue } else { try await createStack(name: "RVRB DJ Queue", activeQueue: true) }

        guard let id = stack["_id"]?.string else { throw RvrbError.server("The queue has no id") }
        return id
    }

    /// Adds tracks and playlists to a stack at `position`, or at the bottom when nil, keeping their order.
    /// Returns the added tracks (a playlist's tracks aren't returned) and how many playlists were added.
    func add(_ items: [SpotifyItem], toStack stackId: String, at position: Int?) async throws -> (tracks: [Track], playlists: Int) {
        let trackIds = items.compactMap { if case .track(let id) = $0 { id } else { nil } }
        let playlists = items.compactMap { if case .playlist(let id) = $0 { "spotify:playlist:\(id)" } else { nil } }
        var added: [Track] = []

        func bottom() async throws -> Int {
            try await stack(id: stackId, page: 0, limit: 1)["totalItems"]?.int ?? 0
        }

        if let position {
            // Each insert at the same position pushes the earlier ones down: insert the last first.
            for playlist in playlists.reversed() {
                try await addPlaylist(stackId: stackId, playlistURI: playlist, position: position)
            }
            if !trackIds.isEmpty {
                added = try await addTracks(stackId: stackId, trackIds: trackIds, position: position)
            }
        } else {
            if !trackIds.isEmpty {
                added = try await addTracks(stackId: stackId, trackIds: trackIds, position: try await bottom())
            }
            for playlist in playlists {
                try await addPlaylist(stackId: stackId, playlistURI: playlist, position: try await bottom())
            }
        }

        return (added, playlists.count)
    }
}

/// A Darwin notification from the share extension to the app: the queue changed, reload it.
nonisolated enum QueueChangeNotification {
    static let name = "is.bes.Rvrb.queueChanged"

    static func post() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(name as CFString), nil, nil, true)
    }
}
