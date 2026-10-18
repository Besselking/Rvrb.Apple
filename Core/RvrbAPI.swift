import Foundation

enum RvrbError: LocalizedError {
    /// The token was refused (401): log in again.
    case unauthorized(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized(let message): "Not logged in (\(message))"
        case .server(let message): message
        }
    }

    /// Spotify no longer accepts the session (`SPOTIFY_TOKEN_REVOKED`), or it now belongs to another Spotify account
    /// (`SPOTIFY_ACCOUNT_MISMATCH`): the server can't play for the user until they log in again.
    nonisolated static func endsSpotifyLogin(_ message: String) -> Bool {
        message.contains("SPOTIFY_TOKEN_REVOKED") || message.contains("SPOTIFY_ACCOUNT_MISMATCH")
            || message.hasSuffix("Log in again.")
    }
}

/// The REST routes the client needs (https://app.rvrb.one/api-docs/openapi.yaml).
final class RvrbAPI {
    nonisolated static let baseURL = URL(string: "https://app.rvrb.one/")!

    private let session: Session
    private let urlSession: URLSession

    init(session: Session) {
        self.session = session
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        urlSession = URLSession(configuration: configuration)
    }

    /// `GET /api/login`: validates the token; returns `{ token, user, chatMaxLength }`.
    func login() async throws -> JSON {
        try await get("api/login")
    }

    /// The channel lists of `GET /api/channels/{list}/{page}`.
    enum ChannelList: String, CaseIterable, Identifiable {
        /// Public channels with at least one user.
        case popular
        /// Channels the user follows.
        case followed
        /// Channels the user created, administers or moderates.
        case mine = "my"
        case all

        var id: String { rawValue }
    }

    /// `GET /api/channels/{list}/{page}`, 16 per page, most users first; `search` matches slug, genre and title.
    func channels(_ list: ChannelList = .popular, search: String = "", page: Int) async throws -> (channels: [Channel], more: Bool) {
        let search = search.trimmingCharacters(in: .whitespaces)
        let query = search.isEmpty ? "" : "?query=\(Self.escape(search))"
        let result = try await get("api/channels/\(list.rawValue)/\(page)\(query)")
        return ((result["channels"]?.array ?? []).compactMap(Channel.init), result["more"]?.bool ?? false)
    }

    /// The ids of every channel the user follows.
    func followedChannelIds() async throws -> Set<String> {
        var ids = Set<String>()
        for page in 0..<10 {
            let result = try await channels(.followed, page: page)
            ids.formUnion(result.channels.map(\.id))
            if !result.more { break }
        }
        return ids
    }

    // MARK: Users

    /// `GET /api/users/{id}/public`: the user as others see them (bio, social links when shown, country…).
    func publicProfile(userId: String) async throws -> JSON {
        try await get("api/users/\(Self.escape(userId))/public")
    }

    /// `GET /api/users/{id}/statistics`: plays summed per period (`today`, `thismonth`, `lastmonth`, `alltime`).
    func statistics(userId: String) async throws -> JSON {
        try await get("api/users/\(Self.escape(userId))/statistics")
    }

    /// `GET /api/users/{id}/achievements`: earned achievements (`title`, `description`, `icon`).
    func achievements(userId: String) async throws -> [JSON] {
        try await get("api/users/\(Self.escape(userId))/achievements").array ?? []
    }

    /// The ids of the users `me` follows, from their own `GET /api/users/{id}/profile`.
    func followedUserIds(me: String) async throws -> Set<String> {
        try await social(me: me).followed
    }

    /// The users `me` follows and has muted, from their own `GET /api/users/{id}/profile`.
    func social(me: String) async throws -> (followed: Set<String>, muted: Set<String>) {
        let profile = try await get("api/users/\(Self.escape(me))/profile")
        func ids(_ key: String) -> Set<String> { Set((profile[key]?.array ?? []).compactMap(\.string)) }
        return (ids("followed"), ids("muted"))
    }

    /// `PUT` / `DELETE /api/users/{me}/muted/{target}`: muted users' chat is hidden.
    func setMuted(_ mute: Bool, me: String, target: String) async throws {
        _ = try await send(mute ? "PUT" : "DELETE", "api/users/\(Self.escape(me))/muted/\(Self.escape(target))")
    }

    /// `PUT` / `DELETE /api/users/{me}/following/{target}`.
    func setFollowingUser(_ follow: Bool, me: String, target: String) async throws {
        _ = try await send(follow ? "PUT" : "DELETE", "api/users/\(Self.escape(me))/following/\(Self.escape(target))")
    }

    /// `PUT` / `DELETE /api/channel/{id}/followers/me`.
    func setFollowing(_ follow: Bool, channelId: String) async throws {
        _ = try await send(follow ? "PUT" : "DELETE", "api/channel/\(Self.escape(channelId))/followers/me")
    }

    /// `GET /api/channel/{id}`: the channel, fresh (descriptions, links, limits, followers).
    func channel(id: String) async throws -> Channel? {
        Channel(try await get("api/channel/\(Self.escape(id))"))
    }

    /// `GET /api/channel/{id}/history`: the tracks played, newest first (`track`, `playedBy`, `voteSummary`,
    /// `timestamp`, `skipped`). Only for users joined to the channel.
    func channelHistory(channelId: String) async throws -> [JSON] {
        try await get("api/channel/\(Self.escape(channelId))/history")["history"]?.array ?? []
    }

    /// `PUT /api/channel/{id}/djs`: the DJs in a new order (moderators and up).
    func reorderDJs(channelId: String, djs: [String]) async throws {
        _ = try await send("PUT", "api/channel/\(Self.escape(channelId))/djs", body: ["djs": .array(djs.map(JSON.string))])
    }

    /// `POST /api/channel/{id}/skip`: skips the playing track; for its DJ, or a moderator and up.
    func skip(channelId: String) async throws {
        _ = try await send("POST", "api/channel/\(Self.escape(channelId))/skip")
    }

    /// `POST /api/firsts`: which of the ISRCs have never been played on RVRB.
    func unplayed(isrcs: [String]) async throws -> Set<String> {
        guard !isrcs.isEmpty else { return [] }
        return Set((try await send("POST", "api/firsts", body: ["isrcs": .array(isrcs.map(JSON.string))]).array ?? [])
            .compactMap(\.string))
    }

    /// `GET /api/channel/{id}/bot`: the channel's own bot (name and pictures); empty when it has none. Only for
    /// users joined to the channel.
    func channelBot(channelId: String) async throws -> JSON {
        try await get("api/channel/\(Self.escape(channelId))/bot")
    }

    /// `GET /api/channel/{id}/bot/options`: the chat commands (`name`, `help`), core ones plus the channel bot's
    /// when it's enabled. `enabled` and `personality` come from the bot record, as the web app passes them.
    func botCommands(channelId: String, enabled: Bool, personality: String?) async throws -> [JSON] {
        var path = "api/channel/\(Self.escape(channelId))/bot/options?enabled=\(enabled)"
        if let personality { path += "&personality=\(Self.escape(personality))" }
        return try await get(path)["commands"]?.array ?? []
    }

    /// `GET /api/channel/{id}/chat`: the last 100 messages; only works once joined over the websocket.
    func chat(channelId: String) async throws -> [JSON] {
        try await get("api/channel/\(Self.escape(channelId))/chat")["chat"]?.array ?? []
    }

    /// `GET /api/music/devices`: the user's running Spotify Connect devices.
    func devices() async throws -> [Device] {
        try await get("api/music/devices")["devices"]?.array?.compactMap(Device.init) ?? []
    }

    /// `PUT /api/music/devices/preferred`: saved by name, so it survives device id changes.
    func setPreferredDevice(name: String) async throws {
        _ = try await send("PUT", "api/music/devices/preferred", body: ["device_name": .string(name)])
    }

    /// `PUT /api/music/devices/volume`.
    func setVolume(_ percent: Int, deviceId: String) async throws {
        _ = try await send("PUT", "api/music/devices/volume",
                           body: ["device_id": .string(deviceId), "volume_percent": .number(Double(percent))])
    }

    /// `GET /api/music/search`: Spotify's search response passed through.
    func searchTracks(_ query: String, limit: Int = 30) async throws -> [Track] {
        let result = try await get("api/music/search?type=track&limit=\(limit)&q=\(Self.escape(query))")
        return (result["tracks"]?["items"]?.array ?? []).compactMap(Track.init)
    }

    /// The bookmark ("starred") playlist URI. When the user has no default playlists yet, `PUT` creates them first.
    func starredPlaylistURI() async throws -> String {
        var defaults = try await get("api/music/playlist/defaults")["result"]

        if defaults?["spotifyStarredUri"]?.nonEmptyString == nil {
            defaults = try await send("PUT", "api/music/playlist/defaults", body: [:])["result"]
        }

        guard let uri = defaults?["spotifyStarredUri"]?.nonEmptyString else {
            throw RvrbError.server("You have no bookmark playlist")
        }
        return uri
    }

    /// `POST /api/music/playlist/{id}/tracks`; the id can be the playlist URI's last part.
    func addToPlaylist(_ playlistURI: String, trackURIs: [String]) async throws {
        let id = playlistURI.split(separator: ":").last.map(String.init) ?? playlistURI
        _ = try await send("POST", "api/music/playlist/\(Self.escape(id))/tracks",
                           body: ["uris": .array(trackURIs.map(JSON.string))])
    }

    // MARK: Stacks (the DJ queue is the one with `activeQueue: true`)

    func stacks() async throws -> [JSON] {
        try await get("api/music/stack")["result"]?.array ?? []
    }

    func createStack(name: String, activeQueue: Bool) async throws -> JSON {
        let result = try await send("POST", "api/music/stack",
                                    body: ["name": .string(name), "activeQueue": .bool(activeQueue), "tracks": []])
        guard let stack = result["result"] else { throw RvrbError.server("The new queue was not returned") }
        return stack
    }

    /// A page of full track objects (`tracks`) and the stack's `totalItems`; `limit` is capped at 50.
    func stack(id: String, page: Int, limit: Int) async throws -> JSON {
        guard let stack = try await get("api/music/stack/\(Self.escape(id))?page=\(page)&limit=\(limit)")["result"] else {
            throw RvrbError.server("The queue was not returned")
        }
        return stack
    }

    /// Inserts at `position` (zero-based; the server's default is 0, the top); returns the added tracks.
    @discardableResult
    func addTracks(stackId: String, trackIds: [String], position: Int) async throws -> [Track] {
        let result = try await send("POST", "api/music/stack/\(Self.escape(stackId))/tracks",
                                    body: ["trackIds": .array(trackIds.map(JSON.string)), "position": .number(Double(position))])
        return (result["result"]?["tracks"]?.array ?? []).compactMap(Track.init)
    }

    /// Inserts every track of a Spotify playlist (`spotify:playlist:…`) at `position`.
    func addPlaylist(stackId: String, playlistURI: String, position: Int) async throws {
        _ = try await send("POST", "api/music/stack/\(Self.escape(stackId))/tracks",
                           body: ["fromPlaylistUri": .string(playlistURI), "position": .number(Double(position))])
    }

    /// Moves one track; `targetPosition` counts after its removal.
    func moveTrack(stackId: String, from position: Int, to targetPosition: Int) async throws {
        _ = try await send("PATCH", "api/music/stack/\(Self.escape(stackId))/tracks",
                           body: ["position": .number(Double(position)), "targetPosition": .number(Double(targetPosition)), "length": 1])
    }

    /// `POST /api/music/stack/{id}/shuffle`: puts the stack's tracks in random order.
    func shuffleStack(id: String) async throws {
        _ = try await send("POST", "api/music/stack/\(Self.escape(id))/shuffle")
    }

    func removeTrack(stackId: String, at position: Int) async throws {
        _ = try await send("DELETE", "api/music/stack/\(Self.escape(stackId))/tracks/\(position)")
    }

    // MARK: Plumbing

    private func get(_ path: String) async throws -> JSON {
        try await send("GET", path)
    }

    private func send(_ method: String, _ path: String, body: JSON? = nil) async throws -> JSON {
        guard let url = URL(string: path, relativeTo: Self.baseURL) else { throw RvrbError.server("Bad path \(path)") }
        guard let token = session.token else { throw RvrbError.unauthorized("no token") }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "accept")

        if let body {
            request.httpBody = try body.data()
            request.setValue("application/json", forHTTPHeaderField: "content-type")
        }

        let (data, response) = try await urlSession.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0

        if let updated = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "update-token"), !updated.isEmpty {
            session.update(updated)
        }

        let text = String(decoding: data, as: UTF8.self)

        if status == 401 {
            throw RvrbError.unauthorized(text.isEmpty ? "Unauthorized" : text)
        }

        guard (200..<300).contains(status) else {
            // Error bodies are `{ error }` or plain text.
            let message = (try? JSON(parsing: data))?["error"]?.string ?? text
            if RvrbError.endsSpotifyLogin(message) {
                session.loginLost(message)
                throw RvrbError.unauthorized(message)
            }
            throw RvrbError.server("\(status): \(message.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : message)")
        }

        return data.isEmpty ? .null : ((try? JSON(parsing: data)) ?? .string(text))
    }

    /// User images are full URLs (e.g. from Spotify) or, for uploads, paths like `/static/abc.png` on RVRB.
    nonisolated static func imageURL(_ value: JSON?) -> URL? {
        guard let text = value?.nonEmptyString, !text.hasPrefix("data:") else { return nil }
        if text.hasPrefix("http://") || text.hasPrefix("https://") { return URL(string: text) }
        if text.hasPrefix("//") { return URL(string: "https:" + text) }
        return URL(string: text.hasPrefix("/") ? String(text.dropFirst()) : text, relativeTo: baseURL)?.absoluteURL
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?/#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
