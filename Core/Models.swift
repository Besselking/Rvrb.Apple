import Foundation

/// A Spotify track object, kept whole: the server wants the full object back when this client DJs.
struct Track: Identifiable, Hashable {
    let json: JSON

    init?(_ json: JSON?) {
        guard let json, json.object != nil else { return nil }
        self.json = json
    }

    var id: String { json["id"]?.string ?? uri ?? "" }
    var name: String { json["name"]?.nonEmptyString ?? "Unknown track" }
    var uri: String? { json["uri"]?.nonEmptyString }
    var album: String? { json["album"]?["name"]?.nonEmptyString }
    var duration: TimeInterval { (json["duration_ms"]?.double ?? 0) / 1000 }

    var artists: String {
        (json["artists"]?.array ?? []).compactMap { $0["name"]?.nonEmptyString }.joined(separator: ", ")
    }

    /// The smallest album image at least `minWidth` points wide, or the largest there is.
    func artworkURL(minWidth: Double = 0) -> URL? {
        let images = (json["album"]?["images"]?.array ?? [])
            .compactMap { image -> (width: Double, url: URL)? in
                guard let url = image["url"]?.string.flatMap(URL.init(string:)) else { return nil }
                return (image["width"]?.double ?? 0, url)
            }
            .sorted { $0.width < $1.width }

        return (images.first { $0.width >= minWidth } ?? images.last)?.url
    }
}

/// A channel from `GET /api/channels/...`. Equal by id, so a reloaded list keeps its selection.
struct Channel: Identifiable, Hashable {
    let json: JSON

    init?(_ json: JSON?) {
        guard let json, json["_id"]?.string ?? json["id"]?.string != nil else { return nil }
        self.json = json
    }

    var id: String { json["_id"]?.string ?? json["id"]?.string ?? "" }

    var title: String { json["title"]?.nonEmptyString ?? json["slug"]?.nonEmptyString ?? "Untitled channel" }
    var genre: String? { json["genre"]?.nonEmptyString }
    var greeting: String? { json["greeting"]?.nonEmptyString }

    /// `users` is an array of the users in it.
    var listenerCount: Int { json["users"]?.array?.count ?? 0 }

    var djIds: [String] { (json["djs"]?.array ?? []).compactMap(\.string) }

    /// `nowPlaying` holds the current track; accept it bare or wrapped in `track`.
    var nowPlaying: Track? {
        let item = json["nowPlaying"]
        return Track(item?["track"]) ?? (item?["name"] != nil ? Track(item) : nil)
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// The logged-in user, from `GET /api/login`.
struct Me: Hashable {
    let id: String
    let displayName: String?
    let userName: String?

    init(_ json: JSON?) {
        id = json?["_id"]?.string ?? json?["id"]?.string ?? ""
        displayName = json?["displayName"]?.nonEmptyString
        userName = json?["userName"]?.nonEmptyString
    }

    var name: String { displayName ?? userName ?? "You" }
}

/// A user in the joined channel (`updateChannelUsers`).
struct ChannelUser: Identifiable, Hashable {
    let id: String
    let name: String
    let userName: String?
    let imageURL: URL?
    /// Shown while the user DJs, and after they doped or noped the playing track (custom uploads, often unset).
    let djImageURL: URL?
    let dopeImageURL: URL?
    let nopeImageURL: URL?
    let role: Int
    let mobile: Bool

    init?(_ json: JSON) {
        guard let id = json["_id"]?.string else { return nil }
        self.id = id
        userName = json["userName"]?.nonEmptyString
        name = json["displayName"]?.nonEmptyString ?? userName ?? "Unknown"
        imageURL = RvrbAPI.imageURL(json["image"])
        djImageURL = RvrbAPI.imageURL(json["djImage"])
        dopeImageURL = RvrbAPI.imageURL(json["thumbsUpImage"])
        nopeImageURL = RvrbAPI.imageURL(json["thumbsDownImage"])
        // The spec has `role`, the server doesn't send it (roles live in the channel's `roles`).
        role = json["role"]?.int ?? 0
        mobile = json["mobile"]?.bool ?? false
    }
}

/// A Spotify Connect device (`GET /api/music/devices`).
struct Device: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
    let isPreferred: Bool
    let isRestricted: Bool

    init?(_ json: JSON) {
        guard let id = json["id"]?.nonEmptyString else { return nil }
        self.id = id
        name = json["name"]?.nonEmptyString ?? id
        type = json["type"]?.string ?? ""
        isActive = json["is_active"]?.bool ?? false
        isPreferred = json["is_preferred"]?.bool ?? false
        isRestricted = json["is_restricted"]?.bool ?? false
    }

    var systemImage: String {
        switch type.lowercased() {
        case "computer": "laptopcomputer"
        case "smartphone": "iphone"
        case "tablet": "ipad"
        case "speaker": "hifispeaker"
        case "tv", "castvideo": "tv"
        case "automobile": "car"
        case "gameconsole": "gamecontroller"
        default: "hifispeaker.and.homepod"
        }
    }
}

extension TimeInterval {
    /// "3:07", or "1:02:03" from an hour.
    var minutesAndSeconds: String {
        let total = Int(self.rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
