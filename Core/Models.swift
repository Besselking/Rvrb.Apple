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
    /// The recording's ISRC, which RVRB keys first plays by.
    var isrc: String? { json["external_ids"]?["isrc"]?.nonEmptyString }

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
    var slug: String? { json["slug"]?.nonEmptyString }
    var infoLink: URL? { json["infoLink"]?.nonEmptyString.flatMap(URL.init(string:)) }
    var calendarLink: URL? { json["channelCalendarLink"]?.nonEmptyString.flatMap(URL.init(string:)) }
    var promoImageURL: URL? { RvrbAPI.imageURL(json["promoImageUrl"]) }
    var promoLink: URL? { json["promoImageHref"]?.nonEmptyString.flatMap(URL.init(string:)) }
    var followerCount: Int? { json["followers"]?.array?.count }
    var maxDJs: Int? { json["limitDjs"]?.bool == false ? nil : json["maxDjs"]?.int }
    var maxTurns: Int? { json["maxTurns"]?.int }
    var created: Date? { json["createdDate"]?.string.flatMap(Date.init(rvrb:)) }

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
    /// An external bot user (`type: "bot"`), or the channel's own bot.
    let isBot: Bool

    /// `id` overrides the document's: the channel's bot record has its own `_id`, but it chats and DJs as "bot".
    init?(_ json: JSON, id: String? = nil) {
        guard let id = id ?? json["_id"]?.string else { return nil }
        self.id = id
        isBot = id == "bot" || json["type"]?.string == "bot"
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

/// A role in a channel, highest first (the channel's `roles` lists ids per role).
enum ChannelRole: Int, Comparable {
    case mod = 3, admin = 5, creator = 10

    var title: String {
        switch self {
        case .creator: "Creator"
        case .admin: "Admin"
        case .mod: "Mod"
        }
    }

    var systemImage: String {
        switch self {
        case .creator: "crown.fill"
        case .admin: "shield.lefthalf.filled"
        case .mod: "checkmark.shield"
        }
    }

    static func < (lhs: ChannelRole, rhs: ChannelRole) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension Channel {
    /// A user's highest role here, if any.
    func role(of userId: String) -> ChannelRole? {
        let roles = json["roles"]
        func listed(_ key: String) -> Bool { (roles?[key]?.array ?? []).contains { $0.string == userId } }
        if listed("creators") { return .creator }
        if listed("admins") { return .admin }
        if listed("mods") { return .mod }
        return nil
    }
}

/// A chat command (typed as `/name` or `!name`), from the channel's bot options.
struct BotCommand: Identifiable, Hashable {
    let name: String
    let help: String?

    var id: String { name }

    init?(_ json: JSON) {
        guard let name = json["name"]?.nonEmptyString else { return nil }
        self.name = name
        help = json["help"]?.nonEmptyString
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
    let volume: Int?
    let supportsVolume: Bool

    init?(_ json: JSON) {
        guard let id = json["id"]?.nonEmptyString else { return nil }
        volume = json["volume_percent"]?.int
        supportsVolume = json["supports_volume"]?.bool ?? (json["volume_percent"]?.int != nil)
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

extension Date {
    /// RVRB dates: ISO 8601 with or without milliseconds, or epoch milliseconds/seconds.
    init?(rvrb text: String) {
        if let number = Double(text) {
            self = Date(timeIntervalSince1970: number > 1e11 ? number / 1000 : number)
        } else if let date = (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
                    ?? (try? Date(text, strategy: .iso8601)) {
            self = date
        } else {
            return nil
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
