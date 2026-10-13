import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Everything about the logged-in user's session in a channel: the websocket, the joined channel's chat, people,
/// playing track and votes, DJing from the queue, and playback on Spotify.
@Observable
final class RvrbClient {
    static let maxMessages = 500

    let me: Me
    let api: RvrbAPI
    let socket: RvrbSocket
    let queue: TrackQueue
    let player: Player
    let chatMaxLength: Int

    /// The joined channel.
    private(set) var channel: Channel?
    /// The channel being joined (or waiting for the connection to join).
    private(set) var joining: Channel?
    private(set) var messages: [ChatMessage] = []
    /// Users in the channel, sorted by name.
    private(set) var users: [ChannelUser] = []
    /// DJ ids in play order: the first is playing.
    private(set) var djIds: [String] = []
    private(set) var nowPlaying: NowPlaying?
    /// A failed join, to show as an alert (the chat isn't on screen then).
    var joinError: String?

    @ObservationIgnored private var seen: Set<String> = []
    @ObservationIgnored private var names: [String: String] = [:]
    @ObservationIgnored private var pendingJoin: Channel?
    /// The track this client last gave the server for its turn; taken off the queue once it starts playing.
    @ObservationIgnored private var answeredTrackId: String?
    @ObservationIgnored private var starredPlaylist: String?
    /// "@name" mentions to highlight: the display name and the username.
    @ObservationIgnored private let mentions: [String]
    @ObservationIgnored private var isHidden = false

    init(api: RvrbAPI, session: Session, me: Me, chatMaxLength: Int) {
        self.api = api
        self.me = me
        self.chatMaxLength = chatMaxLength
        socket = RvrbSocket(session: session)
        queue = TrackQueue(api: api)
        player = Player(socket: socket)
        mentions = Set([me.displayName, me.userName].compactMap { $0?.trimmingCharacters(in: .whitespaces) })
            .filter { !$0.isEmpty }
            .map { "@" + $0 }

        socket.onReady = { [weak self] in self?.socketReady() }
        socket.onNotification = { [weak self] method, params in self?.handle(method, params) }
        socket.requestHandler = { [weak self] method, params in
            guard let self else { throw RvrbError.server("Gone") }
            return try await self.answer(method, params)
        }
        player.onError = { [weak self] message in
            self?.addNotice("Playback: \(message). Pick a Spotify device, or turn playback off.")
        }
    }

    func start() {
        socket.start()
        Task { await loadQueue() }
    }

    /// Stops playback and leaves the channel (send `leave` on exit: without it the account stays in the channel).
    func shutdown() async {
        await leave()
        socket.stop()
    }

    // MARK: People

    var isDJ: Bool { djIds.contains(me.id) }
    var isMyTurn: Bool { djIds.first == me.id }

    func name(for userId: String) -> String {
        if userId == me.id { return me.name }
        return names[userId] ?? (userId == "bot" ? "Bot" : "Unknown DJ")
    }

    var listeners: [ChannelUser] {
        let onDecks = Set(djIds)
        return users.filter { !onDecks.contains($0.id) }
    }

    func user(_ id: String) -> ChannelUser? {
        users.first { $0.id == id }
    }

    // MARK: Joining

    func join(_ channel: Channel) async {
        guard channel.id != self.channel?.id, channel.id != joining?.id else { return }

        joining = channel

        // Picked before the websocket is ready (e.g. right at launch): join once it is.
        guard socket.isReady else {
            pendingJoin = channel
            return
        }

        // Reset before sending `join`: the server pushes the track, DJs and users right after its answer, which can
        // be handled before the code after the await runs.
        let previous = self.channel
        self.channel = nil
        users = []
        names = [:]
        djIds = channel.djIds
        nowPlaying = nil
        messages = []
        seen = []

        do {
            if previous != nil {
                // The new channel's track arrives after joining; don't keep playing the old one meanwhile.
                await player.stop()
                _ = try? await socket.request("leave")
            }
            try await socket.request("join", ["channelId": .string(channel.id)])
        } catch {
            if joining?.id == channel.id { joining = nil }
            joinError = "Could not join \(channel.title): \(Self.describeJoinError(error))"
            return
        }

        guard joining?.id == channel.id else { return }
        joining = nil
        self.channel = channel

        if let greeting = channel.greeting {
            addNotice(ChatText.parse(.string(greeting)).plain)
        }

        await loadBacklog(channelId: channel.id)
    }

    func leave() async {
        pendingJoin = nil
        joining = nil
        guard channel != nil else { return }

        await player.stop()
        _ = try? await socket.request("leave", timeout: .seconds(3))
        clearChannel()
    }

    private func clearChannel() {
        channel = nil
        users = []
        names = [:]
        djIds = []
        nowPlaying = nil
        answeredTrackId = nil
    }

    /// Join refusals look like "PR:Password required to join <title>": show the part after the code.
    private static func describeJoinError(_ error: Error) -> String {
        let message = error.localizedDescription
        if let colon = message.firstIndex(of: ":"), (1...4).contains(message.distance(from: message.startIndex, to: colon)) {
            return message[message.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return message
    }

    private func socketReady() {
        #if os(iOS)
        sendAppState()
        #endif

        if let pending = pendingJoin {
            pendingJoin = nil
            joining = nil
            Task { await join(pending) }
        } else if let channel {
            // After a reconnect the server has forgotten the channel: join again and fill the gap in the chat.
            Task {
                do {
                    try await socket.request("join", ["channelId": .string(channel.id)])
                    await loadBacklog(channelId: channel.id)
                } catch {
                    addNotice("Could not rejoin \(channel.title): \(Self.describeJoinError(error))")
                }
            }
        }
    }

    private func loadBacklog(channelId: String) async {
        do {
            let chat = try await api.chat(channelId: channelId)
            guard channel?.id == channelId else { return }

            for message in chat {
                add(message, live: false)
            }
            // The backlog and live messages overlap and interleave.
            messages.sort { $0.time < $1.time }
        } catch {
            addNotice("Could not load the chat history: \(error.localizedDescription)")
        }
    }

    // MARK: App state (iOS)

    /// A hidden mobile client gets no heartbeats and is kept for an hour after its socket closes. For a mobile
    /// client with Spotify the server starts playback itself (`playChannelTrack` then has `playTrack: false`).
    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        #if os(iOS)
        if !hidden { socket.reconnectIfNeeded() }
        sendAppState()
        #endif
    }

    private func sendAppState() {
        guard socket.isReady else { return }
        let hidden = isHidden
        Task { try? await socket.notify("appState", ["hidden": .bool(hidden), "mobile": true]) }
    }

    // MARK: Chat

    /// Sends a chat message. It comes back as `pushChannelMessage`, so it isn't added here.
    func send(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        guard channel != nil else {
            addNotice("Join a channel first.")
            return false
        }

        do {
            // The server never answers pushMessage, so it goes without an id.
            try await socket.notify("pushMessage", ["payload": .string(text), "type": "chat"])
            return true
        } catch {
            addNotice("Not sent: \(error.localizedDescription)")
            return false
        }
    }

    func addNotice(_ text: String) {
        append(ChatMessage(id: UUID().uuidString, time: .now, userId: nil, name: "", kind: .notice,
                           body: ChatText.Body(text: AttributedString(text), plain: text, images: []),
                           isMine: false, mentionsMe: false))
    }

    private func add(_ json: JSON?, live: Bool) {
        guard let m = json, m.object != nil, m["deleted"]?.bool != true else { return }

        let syncTime = m["syncTime"]?.double ?? Date.now.timeIntervalSince1970 * 1000
        let userId = m["userId"]?.string ?? ""
        let key = "\(syncTime):\(userId)"

        // The backlog and the live stream overlap after joining or reconnecting.
        guard seen.insert(key).inserted else { return }

        let name = switch userId {
        case "server": "RVRB"
        case me.id: me.name
        default: names[userId] ?? m["userName"]?.nonEmptyString ?? m["displayName"]?.nonEmptyString ?? (userId == "bot" ? "Bot" : "Unknown")
        }

        let type = m["type"]?.string ?? "chat"
        var body = ChatText.parse(m["payload"])

        if type == "play" {
            // "Artist::Title"
            let parts = body.plain.components(separatedBy: "::")
            if parts.count == 2 {
                let text = "\(parts[1]) — \(parts[0])"
                body = ChatText.Body(text: AttributedString(text), plain: text, images: [])
            }
        }

        if m["expandable"]?.bool == true, let summary = m["summary"]?.nonEmptyString {
            let summaryBody = ChatText.parse(.string(summary))
            body = ChatText.Body(text: summaryBody.text + "\n" + body.text, plain: summaryBody.plain + "\n" + body.plain,
                                 images: summaryBody.images + body.images)
        }

        let kind: ChatMessage.Kind = switch type {
        case "whisper": .whisper
        case "alert": .alert
        case "play": .play
        case "botResponse": .bot
        default: userId == "server" ? .alert : (userId == "bot" ? .bot : .chat)
        }

        let isMine = userId == me.id
        let mentionsMe = !isMine && (kind == .whisper || mentions.contains { body.plain.localizedCaseInsensitiveContains($0) })

        let message = ChatMessage(id: key, time: Date(timeIntervalSince1970: syncTime / 1000), userId: userId, name: name,
                                  kind: kind, body: body, isMine: isMine, mentionsMe: mentionsMe)

        // The backlog loaded on join doesn't call for attention, only live messages do.
        if live && mentionsMe { requestAttention() }

        append(message)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    private func requestAttention() {
        #if os(macOS)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        #endif
    }

    // MARK: Notifications

    private func handle(_ method: String, _ p: JSON?) {
        switch method {
        case "pushChannelMessage":
            add(p, live: true)

        case "updateChannelUsers":
            if let list = p?["users"]?.array { updateUsers(list) }

        case "updateChannelDjs":
            if let list = p?["djs"]?.array { djIds = list.compactMap(\.string) }

        case "playChannelTrack":
            setTrack(p)

            // Our answer to nextChannelTrack is playing: take it off the queue (the server doesn't).
            if let answered = answeredTrackId, p?["track"]?["id"]?.string == answered {
                answeredTrackId = nil
                Task {
                    do { try await queue.removePlayed(trackId: answered) } catch {
                        addNotice("Could not take the played track off your queue: \(error.localizedDescription)")
                    }
                }
            }

            let uri = p?["track"]?["uri"]?.string
            let serverPlays = p?["playTrack"]?.bool == false
            Task { await player.channelTrack(uri: uri, serverPlays: serverPlays) }

        case "pauseChannelTrack":
            nowPlaying = nil
            Task { await player.stop() }

        case "refreshDjStack":
            Task { await loadQueue() }

        case "updateChannelMeter":
            // The spec nests the votes in `voting`; take params itself if they aren't.
            if let voting = p?["voting"] ?? p { setVotes(voting) }

        case "activePlayer":
            player.activePlayer(deviceId: p?["device_id"]?.string)

        case "clearChannelMessages":
            if let times = p?["syncTime"]?.array {
                let removed = Set(times.compactMap(\.double).map { Date(timeIntervalSince1970: $0 / 1000) })
                messages.removeAll { $0.kind != .notice && removed.contains($0.time) }
            } else {
                messages.removeAll()
                addNotice("The chat was cleared.")
            }

        case "leaveChannel":
            if let channel, p?["channelId"]?.string == channel.id {
                addNotice("You are no longer in \(channel.title).")
                clearChannel()
                Task { await player.stop() }
            }

        case "pushNotification":
            if let n = p?["notification"] {
                let title = n["title"]?.string ?? "Notification"
                addNotice("🔔 \(title): \(ChatText.parse(n["message"]).plain)")
            }

        default:
            break
        }
    }

    private func updateUsers(_ list: [JSON]) {
        users = list.compactMap(ChannelUser.init)
            .sorted { ($0.role, $1.name.lowercased()) > ($1.role, $0.name.lowercased()) }
        names = Dictionary(users.map { ($0.id, $0.name) }) { first, _ in first }
    }

    // MARK: Playing track and votes

    /// From `playChannelTrack`. The clocks can differ, so `endsAt` is placed on the local clock with the server's
    /// `syncTime` (its time when it sent the message).
    private func setTrack(_ p: JSON?) {
        guard let track = Track(p?["track"]) else {
            nowPlaying = nil
            return
        }

        let now = Date.now.timeIntervalSince1970 * 1000
        let offset = (p?["syncTime"]?.double ?? now) - now
        let duration = track.duration * 1000
        let endsAt = p?["endsAt"]?.double ?? (now + offset + duration)
        let start = Date(timeIntervalSince1970: (endsAt - offset - duration) / 1000)

        nowPlaying = NowPlaying(track: track, start: start)
        if let voting = p?["voting"] { setVotes(voting) }
    }

    /// The spec promises `{ dope, nope, star }` totals; the server sends an entry per voter keyed by user id, e.g.
    /// `{ "<id>": { "dope": 1, "nope": 0, "star": 0 } }`, so those are counted. Totals are still read, should the
    /// server ever send them.
    private func setVotes(_ voting: JSON) {
        guard var playing = nowPlaying, let votes = voting.object else { return }

        var tally = Votes()

        if let dope = voting["dope"]?.int, let nope = voting["nope"]?.int {
            // Plain totals don't say who voted: keep the vote this client last sent.
            tally = Votes(dope: dope, nope: nope, star: voting["star"]?.int ?? 0, mine: playing.votes.mine)
        } else {
            for (voter, entry) in votes {
                let (dope, nope, star) = (entry["dope"]?.isOn ?? false, entry["nope"]?.isOn ?? false, entry["star"]?.isOn ?? false)
                tally.dope += dope ? 1 : 0
                tally.nope += nope ? 1 : 0
                tally.star += star ? 1 : 0
                if voter == me.id { tally.mine = MyVote(dope: dope, nope: nope, star: star) }
            }
        }

        playing.votes = tally
        nowPlaying = playing
    }

    /// Toggles a vote. Only the toggled key is sent, so a vote made in another client isn't overwritten. Dope and
    /// nope exclude each other on the server; star (a bookmark) is separate.
    func vote(_ kind: VoteKind) async {
        guard channel != nil, let playing = nowPlaying else { return }

        var next = playing.votes.mine
        let params: JSON

        switch kind {
        case .dope:
            next.dope.toggle()
            if next.dope { next.nope = false }
            params = ["dope": .bool(next.dope)]
        case .nope:
            next.nope.toggle()
            if next.nope { next.dope = false }
            params = ["nope": .bool(next.nope)]
        case .star:
            next.star.toggle()
            params = ["star": .bool(next.star)]
        }

        do {
            try await socket.request("vote", params)

            // The server's next meter update confirms it; show it now.
            if nowPlaying?.track.id == playing.track.id {
                nowPlaying?.votes.mine = next
            }

            // The server records the star but doesn't touch the bookmark playlist; the web app adds it itself.
            if kind == .star, next.star, let uri = playing.track.uri {
                await bookmark(uri, title: playing.track.name)
            }
        } catch {
            addNotice("Vote not counted: \(error.localizedDescription)")
        }
    }

    private func bookmark(_ uri: String, title: String) async {
        do {
            if starredPlaylist == nil { starredPlaylist = try await api.starredPlaylistURI() }
            try await api.addToPlaylist(starredPlaylist!, trackURIs: [uri])
            addNotice("Bookmarked \(title).")
        } catch {
            addNotice("Starred, but not added to your bookmark playlist: \(error.localizedDescription)")
        }
    }

    // MARK: DJing

    func toggleDJ() async {
        guard channel != nil else { return }
        let onDecks = isDJ

        if !onDecks, queue.isLoaded, queue.total == 0 {
            addNotice("Your queue is empty: add tracks before stepping up.")
            return
        }

        do {
            try await socket.request(onDecks ? "leaveDjs" : "joinDjs")
        } catch {
            addNotice("Could not step \(onDecks ? "down" : "up"): \(error.localizedDescription)")
        }
    }

    /// `nextChannelTrack` comes when it's this DJ's turn and must be answered within 2.5 s with a full track object.
    /// An error answer takes the DJ off the decks, which is right for an empty queue.
    private func answer(_ method: String, _ params: JSON?) async throws -> JSON {
        guard method == "nextChannelTrack" else { throw RvrbError.server("\(method) is not supported") }

        if !queue.isLoaded { try await queue.reload() }

        guard let track = queue.next else {
            addNotice("Your queue is empty, so you were taken off the decks.")
            throw RvrbError.server("The queue is empty")
        }

        answeredTrackId = track.id
        return ["track": track.json]
    }

    func loadQueue() async {
        do {
            try await queue.reload()
        } catch {
            addNotice("Could not load your queue: \(error.localizedDescription)")
        }
    }
}
