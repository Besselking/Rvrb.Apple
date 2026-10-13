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

    /// `GET /api/channels/{query}/{page}`, 16 per page. Without search text: the popular channels (public, at least
    /// one user, most users first); with it, all channels matching slug, genre or title.
    func channels(search: String, page: Int) async throws -> (channels: [Channel], more: Bool) {
        let search = search.trimmingCharacters(in: .whitespaces)
        let path = search.isEmpty ? "api/channels/popular/\(page)" : "api/channels/all/\(page)?query=\(Self.escape(search))"
        let result = try await get(path)
        return ((result["channels"]?.array ?? []).compactMap(Channel.init), result["more"]?.bool ?? false)
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

    /// Inserts at `position` (zero-based; the server's default is 0, the top).
    func addTracks(stackId: String, trackIds: [String], position: Int) async throws {
        _ = try await send("POST", "api/music/stack/\(Self.escape(stackId))/tracks",
                           body: ["trackIds": .array(trackIds.map(JSON.string)), "position": .number(Double(position))])
    }

    /// Moves one track; `targetPosition` counts after its removal.
    func moveTrack(stackId: String, from position: Int, to targetPosition: Int) async throws {
        _ = try await send("PATCH", "api/music/stack/\(Self.escape(stackId))/tracks",
                           body: ["position": .number(Double(position)), "targetPosition": .number(Double(targetPosition)), "length": 1])
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
