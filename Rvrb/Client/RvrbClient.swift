import Foundation
import Observation
import os
#if os(macOS)
import AppKit
#else
import UIKit
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
    /// Each voter's votes on the playing track, by user id.
    private(set) var voters: [String: MyVote] = [:]
    // Observed (not ignored): chat rows look people up here, and must redraw when they arrive after the messages.
    private var usersById: [String: ChannelUser] = [:]
    /// The channel's own bot, which chats (and can DJ) as the user id "bot" or as its record's ids.
    private(set) var channelBot: ChannelUser?
    /// The chat commands the channel offers, for completion in the message box.
    private(set) var botCommands: [BotCommand] = []
    @ObservationIgnored private var channelBotConfig: JSON?
    private var channelBotIds = RvrbClient.defaultBotIds
    /// The channel's bot chats as "bot" or as the number 0 (seen on the live server).
    private static let defaultBotIds: Set<String> = ["bot", "0"]
    /// Joined on the current connection: `join` was answered since the socket last connected.
    private(set) var isInRoom = false
    /// Ids of the channels the user follows.
    private(set) var followedChannelIds: Set<String> = []
    /// When each person was last seen typing (on this clock), for "… is typing".
    private(set) var typingSince: [String: Date] = [:]
    @ObservationIgnored private var lastTyping: [String: Double] = [:]
    @ObservationIgnored private var sentTypingAt: Date = .distantPast

    /// The tracks the joined channel played, newest first, for "n plays ago" in the queue.
    private(set) var recentPlays: [PlayedTrack] = []

    struct PlayedTrack: Equatable {
        let id: String
        let isrc: String?

        init(_ track: Track) {
            id = track.id
            isrc = track.isrc
        }

        /// The same track, or another release of the same recording.
        func matches(_ track: Track) -> Bool {
            id == track.id || (isrc != nil && isrc == track.isrc)
        }
    }

    /// How many tracks ago the channel played this one: 0 while it's playing, nil when not recently.
    func playsAgo(_ track: Track) -> Int? {
        guard channel != nil else { return nil }
        if let playing = nowPlaying?.track, PlayedTrack(playing).matches(track) { return 0 }
        return recentPlays.firstIndex { $0.matches(track) }.map { $0 + 1 }
    }

    /// A track finished (or was skipped): it's now one play ago.
    private func recordPlayed(_ track: Track?) {
        guard let track else { return }
        let played = PlayedTrack(track)
        guard recentPlays.first != played else { return }
        recentPlays.insert(played, at: 0)
        if recentPlays.count > 200 { recentPlays.removeLast(recentPlays.count - 200) }
    }

    private func loadPlayHistory(channelId: String) async {
        do {
            let history = try await api.channelHistory(channelId: channelId).compactMap { Track($0["track"]) }
            guard channel?.id == channelId else { return }
            var plays = history.map(PlayedTrack.init)
            // The history may already hold the track that's playing.
            if let playing = nowPlaying?.track, plays.first?.id == playing.id { plays.removeFirst() }
            recentPlays = plays
        } catch {
            Log.app.error("Could not load the play history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The message the next one sent answers.
    var replyingTo: ChatMessage?
    /// A failed join, to show as an alert (the chat isn't on screen then).
    var joinError: String?

    @ObservationIgnored private var seen: Set<String> = []
    private var names: [String: String] = [:]
    @ObservationIgnored private var pendingJoin: Channel?
    /// The track this client last gave the server for its turn; taken off the queue once it starts playing.
    @ObservationIgnored private var answeredTrackId: String?
    @ObservationIgnored private var starredPlaylist: String?
    /// "@name" mentions to highlight: the display name and the username.
    @ObservationIgnored private let mentions: [String]
    @ObservationIgnored private var isHidden = RvrbClient.launchedInBackground
    @ObservationIgnored private let notifier = MentionNotifier()
    #if os(iOS)
    @ObservationIgnored private(set) var liveActivity: LiveActivityController!
    @ObservationIgnored private let backgroundGrace = BackgroundGrace(name: "Keep the RVRB connection")
    #endif

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
        socket.onDisconnect = { [weak self] in self?.isInRoom = false }
        socket.onNotification = { [weak self] method, params in self?.handle(method, params) }
        socket.requestHandler = { [weak self] method, params in
            guard let self else { throw RvrbError.server("Gone") }
            return try await self.answer(method, params)
        }
        player.onError = { [weak self] message in
            self?.addNotice("Playback: \(message). Pick a Spotify device, or turn playback off.")
        }
        #if os(iOS)
        liveActivity = LiveActivityController(client: self)
        #endif
    }

    func start() {
        #if os(iOS)
        liveActivity.start()
        #endif
        socket.start()
        // Quit while DJing: back to the channel, on the connection the server kept.
        if let saved = UserDefaults.standard.dictionary(forKey: Self.resumeKey) as? [String: String],
           let channel = Channel(["_id": .string(saved["id"] ?? ""), "title": .string(saved["title"] ?? "")]) {
            UserDefaults.standard.removeObject(forKey: Self.resumeKey)
            Task { await join(channel) }
        }
        Task { await loadQueue() }
        Task { await loadFollowed() }
        Task { await loadSocial() }
    }

    func loadFollowed() async {
        do {
            followedChannelIds = try await api.followedChannelIds()
        } catch {
            Log.app.error("Could not load followed channels: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Ids of the users the user follows; nil until a profile asks.
    private(set) var followedUserIds: Set<String>?
    /// Users whose chat is hidden (muted in this app or the web app).
    private(set) var mutedUserIds: Set<String> = []

    func loadFollowedUsers() async {
        guard followedUserIds == nil else { return }
        await loadSocial()
    }

    /// Who the user follows and has muted.
    func loadSocial() async {
        do {
            (followedUserIds, mutedUserIds) = try await api.social(me: me.id)
        } catch {
            Log.app.error("Could not load followed and muted users: \(error.localizedDescription, privacy: .public)")
        }
    }

    func setMuted(_ mute: Bool, _ userId: String) async throws {
        try await api.setMuted(mute, me: me.id, target: userId)
        if mute { mutedUserIds.insert(userId) } else { mutedUserIds.remove(userId) }
    }

    func isMuted(_ userId: String) -> Bool {
        mutedUserIds.contains(userId)
    }

    func setFollowingUser(_ follow: Bool, _ userId: String) async throws {
        try await api.setFollowingUser(follow, me: me.id, target: userId)
        if follow { followedUserIds?.insert(userId) } else { followedUserIds?.remove(userId) }
    }

    /// Whether a user has a profile to show: not RVRB itself or the channel's own bot.
    func hasProfile(_ userId: String) -> Bool {
        !userId.isEmpty && userId != "server" && !channelBotIds.contains(userId)
    }

    /// The full followed list, loaded by the channel list.
    func replaceFollowed(_ ids: Set<String>) {
        followedChannelIds = ids
    }

    func isFollowing(_ channel: Channel) -> Bool {
        followedChannelIds.contains(channel.id)
    }

    func setFollowing(_ follow: Bool, _ channel: Channel) async {
        // Show it right away; put it back if the server refuses.
        if follow { followedChannelIds.insert(channel.id) } else { followedChannelIds.remove(channel.id) }

        do {
            try await api.setFollowing(follow, channelId: channel.id)
        } catch {
            if follow { followedChannelIds.remove(channel.id) } else { followedChannelIds.insert(channel.id) }
            addNotice("Could not \(follow ? "follow" : "unfollow") \(channel.title): \(error.localizedDescription)")
        }
    }

    /// Stops playback and leaves the channel (send `leave` on exit: without it the account stays in the channel).
    func shutdown() async {
        await leave()
        socket.stop()
    }

    /// The channel to rejoin on the next launch of this copy of the app.
    private static var resumeKey: String { "resumeChannel:" + Bundle.main.bundlePath }

    /// Quitting the app. On the decks, the spot is kept: the server is told this is a hidden mobile client, which
    /// it keeps for an hour after the socket closes and serves its turns for, and the next launch resumes the
    /// connection (same client id) and the channel. Otherwise it leaves, as before.
    func quit() async {
        guard let channel, isDJ, socket.isReady else {
            await shutdown()
            return
        }

        UserDefaults.standard.set(["id": channel.id, "title": channel.title], forKey: Self.resumeKey)
        try? await socket.notify("appState", ["hidden": true, "mobile": true])
        socket.stop()
    }

    // MARK: People

    var isDJ: Bool { djIds.contains(me.id) }
    var isMyTurn: Bool { djIds.first == me.id }

    func name(for userId: String) -> String {
        if userId == me.id { return me.name }
        return names[userId] ?? (channelBotIds.contains(userId) ? channelBot?.name ?? "Bot" : "Unknown DJ")
    }

    var listeners: [ChannelUser] {
        let onDecks = Set(djIds)
        return users.filter { !onDecks.contains($0.id) }
    }

    func user(_ id: String) -> ChannelUser? {
        usersById[id] ?? (channelBotIds.contains(id) ? channelBot : nil)
    }

    func isBot(_ id: String) -> Bool {
        user(id)?.isBot ?? channelBotIds.contains(id)
    }

    /// Only the DJ playing now shows as DJing; anyone else (DJs waiting their turn too) by their vote on the track.
    func activity(of userId: String) -> UserActivity {
        if djIds.first == userId { return .djing }
        if let vote = voters[userId] {
            if vote.dope { return .doped }
            if vote.nope { return .noped }
        }
        return .listening
    }

    /// Whether the user starred (bookmarked) the playing track.
    func hasStarred(_ userId: String) -> Bool {
        voters[userId]?.star == true
    }

    /// The user's picture for what they're doing (their DJ, dope or nope image), falling back to their avatar.
    func avatarURL(for userId: String, fallback: URL? = nil) -> URL? {
        let user = user(userId)
        let base = user?.imageURL ?? fallback
        return switch activity(of: userId) {
        case .djing: user?.djImageURL ?? base
        case .doped: user?.dopeImageURL ?? base
        case .noped: user?.nopeImageURL ?? base
        case .listening: base
        }
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
        isInRoom = false
        users = []
        names = [:]
        usersById = [:]
        voters = [:]
        channelBot = nil
        channelBotConfig = nil
        botCommands = []
        channelBotIds = RvrbClient.defaultBotIds
        djIds = channel.djIds
        nowPlaying = nil
        messages = []
        seen = []
        replyingTo = nil
        typingSince = [:]
        recentPlays = []
        lastTyping = [:]

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
        isInRoom = true
        Task { await loadChannelBot(channelId: channel.id) }

        if let greeting = channel.greeting {
            addNotice(ChatText.parse(.string(greeting)).plain)
        }

        Task { await loadPlayHistory(channelId: channel.id) }
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
        replyingTo = nil
        typingSince = [:]
        recentPlays = []
        lastTyping = [:]
        channel = nil
        isInRoom = false
        users = []
        names = [:]
        usersById = [:]
        voters = [:]
        channelBot = nil
        channelBotConfig = nil
        botCommands = []
        channelBotIds = RvrbClient.defaultBotIds
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
        // Also on the Mac: a connection resumed after quitting while DJing still counts as a hidden mobile one.
        sendAppState()

        if let pending = pendingJoin {
            pendingJoin = nil
            joining = nil
            Task { await join(pending) }
        } else if let channel {
            // After a reconnect the server has forgotten the channel: join again and fill the gap in the chat.
            Task {
                do {
                    try await socket.request("join", ["channelId": .string(channel.id)])
                    isInRoom = true
                    Task { await loadPlayHistory(channelId: channel.id) }
                    await loadBacklog(channelId: channel.id)
                } catch {
                    addNotice("Could not rejoin \(channel.title): \(Self.describeJoinError(error))")
                }
            }
        }
    }

    /// Its messages name it "bot" or 0; its record's ids are added in case they're used too.
    private func setChannelBot(_ bot: JSON) {
        guard bot.object?.isEmpty == false else {
            channelBot = nil
            channelBotConfig = nil
            channelBotIds = RvrbClient.defaultBotIds
            return
        }
        channelBotConfig = bot
        channelBotIds = Self.defaultBotIds.union([bot["id"]?.string, bot["_id"]?.string].compactMap { $0 })
        channelBot = ChannelUser(bot, id: "bot")
    }

    private func loadChannelBot(channelId: String) async {
        do {
            let bot = try await api.channelBot(channelId: channelId)
            guard channel?.id == channelId else { return }
            setChannelBot(bot)
        } catch {
            Log.app.error("Could not load the channel's bot: \(error.localizedDescription, privacy: .public)")
        }
        await loadBotCommands(channelId: channelId)
    }

    /// As the web app: the options for the bot's enabled state and personality, leaving out commands the
    /// channel has switched off (a command with options shows only when its `Enabled` option is on).
    private func loadBotCommands(channelId: String) async {
        let config = channelBotConfig
        do {
            let commands = try await api.botCommands(channelId: channelId, enabled: config?["enabled"]?.bool ?? false,
                                                     personality: config?["personality"]?.nonEmptyString)
            guard channel?.id == channelId else { return }
            botCommands = commands.compactMap(BotCommand.init).filter { command in
                guard let options = config?["commands"]?[command.name]?["options"], options != .null else { return true }
                return options["Enabled"]?["value"]?.isOn ?? false
            }
        } catch {
            Log.app.error("Could not load the chat commands: \(error.localizedDescription, privacy: .public)")
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
    /// client with Spotify the server starts playback itself (`playChannelTrack` then has `playTrack: false`), and
    /// (per the RVRB developers) serves a DJ's next track server-side while the client sleeps, so the app needn't
    /// stay awake for its turns.
    ///
    /// Going to the background also asks iOS for a little more time, so a quick switch (say to Spotify) keeps the
    /// connection; after that the app is suspended until it comes back or a Live Activity vote wakes it.
    func setHidden(_ hidden: Bool) {
        isHidden = hidden
        #if os(iOS)
        if hidden {
            backgroundGrace.begin()
        } else {
            backgroundGrace.end()
            socket.reconnectIfNeeded()
        }
        sendAppState()
        #endif
    }

    #if os(iOS)
    private static var launchedInBackground: Bool {
        UIApplication.shared.applicationState == .background
    }
    #else
    private static let launchedInBackground = false
    #endif

    private func sendAppState() {
        guard socket.isReady else { return }
        let hidden = isHidden
        #if os(iOS)
        let mobile = true
        #else
        let mobile = false
        #endif
        Task { try? await socket.notify("appState", ["hidden": .bool(hidden), "mobile": .bool(mobile)]) }
    }

    // MARK: Chat

    /// Sends a chat message. It comes back as `pushChannelMessage`, so it isn't added here.
    /// Tells the room the user is typing, at most once every few seconds (as the web app does).
    func typed() {
        guard channel != nil, socket.isReady, Date.now.timeIntervalSince(sentTypingAt) > 3 else { return }
        sentTypingAt = .now
        // The web app sends the time; the spec says a boolean, and the server takes either.
        let time = Date.now.timeIntervalSince1970 * 1000
        Task { try? await socket.notify("userStatus", ["typing": .number(time.rounded())]) }
    }

    func send(_ text: String) async -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }

        guard channel != nil else {
            addNotice("Join a channel first.")
            return false
        }

        var params: [String: JSON] = ["payload": .string(text), "type": "chat"]
        // A reply names the answered message by its syncTime (a number, as the web app sends it).
        let reply = replyingTo
        if let syncTime = reply?.syncTime { params["replyTo"] = .number(syncTime) }

        do {
            // The server never answers pushMessage, so it goes without an id.
            try await socket.notify("pushMessage", .object(params))
            if replyingTo?.id == reply?.id { replyingTo = nil }
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
        case _ where channelBotIds.contains(userId):
            channelBot?.name ?? m["displayName"]?.nonEmptyString ?? m["userName"]?.nonEmptyString ?? "Bot"
        default: names[userId] ?? m["userName"]?.nonEmptyString ?? m["displayName"]?.nonEmptyString ?? "Unknown"
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
                                 images: summaryBody.images + body.images,
                                 styles: summaryBody.styles.merging(body.styles) { first, _ in first })
        }

        let kind: ChatMessage.Kind = switch type {
        case "whisper": .whisper
        case "alert": .alert
        case "play": .play
        case "botResponse": .bot
        default: userId == "server" ? .alert : (channelBotIds.contains(userId) ? .bot : .chat)
        }

        let isMine = userId == me.id
        // Whoever sent a message has stopped typing it.
        if live { typingSince[userId] = nil }

        let replyTo = m["replyTo"]?.double
        let answersMe = replyTo.map { syncTime in messages.contains { $0.syncTime == syncTime && $0.isMine } } ?? false
        let mentionsMe = !isMine && !mutedUserIds.contains(userId)
            && (kind == .whisper || answersMe || mentions.contains { body.plain.localizedCaseInsensitiveContains($0) })

        let message = ChatMessage(id: key, time: Date(timeIntervalSince1970: syncTime / 1000), userId: userId, name: name,
                                  kind: kind, body: body, isMine: isMine, mentionsMe: mentionsMe,
                                  avatarURL: RvrbAPI.imageURL(m["image"]), syncTime: syncTime, replyTo: replyTo)

        // The backlog loaded on join doesn't call for attention, only live messages do.
        if live && mentionsMe { requestAttention(for: message) }

        append(message)
    }

    private func append(_ message: ChatMessage) {
        messages.append(message)
        if messages.count > Self.maxMessages {
            messages.removeFirst(messages.count - Self.maxMessages)
        }
    }

    /// A notification while the app isn't in front; in front, the highlighted message is enough.
    private func requestAttention(for message: ChatMessage) {
        #if os(macOS)
        let inFront = NSApp.isActive
        #else
        let inFront = UIApplication.shared.applicationState == .active
        #endif
        guard !inFront, let channel else { return }
        notifier.notify(message, in: channel.title)
    }

    /// The app came to the front.
    func becameActive() {
        notifier.clearDelivered()
    }

    // MARK: Notifications

    private func handle(_ method: String, _ p: JSON?) {
        switch method {
        case "pushChannelMessage":
            add(p, live: true)

        case "updateChannel":
            // After an edit it carries the channel's bot.
            if let bot = p?["bot"], bot.object?.isEmpty == false, let channel {
                setChannelBot(bot)
                Task { await loadBotCommands(channelId: channel.id) }
            }

        case "updateChannelUserStatus":
            // `{ "<user id>": { lastSeen, lastTyping } }`, a few seconds after the fact. Only new typing counts, timed
            // on arrival so the clocks needn't agree; entries from long ago (the first batch after joining) don't.
            let now = Date.now.timeIntervalSince1970 * 1000
            for (userId, entry) in p?.object ?? [:] {
                guard userId != me.id, let typed = entry["lastTyping"]?.double, typed > (lastTyping[userId] ?? 0) else { continue }
                lastTyping[userId] = typed
                if now - typed < 15_000 { typingSince[userId] = .now }
            }

        case "updateChannelUsers":
            if let list = p?["users"]?.array { updateUsers(list) }

        case "updateChannelDjs":
            if let list = p?["djs"]?.array { djIds = list.compactMap(\.string) }

        case "playChannelTrack":
            if let previous = nowPlaying?.track, previous.id != p?["track"]?["id"]?.string {
                recordPlayed(previous)
            }
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
            recordPlayed(nowPlaying?.track)
            nowPlaying = nil
            voters = [:]
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
        users = list.compactMap { ChannelUser($0) }
            .sorted { ($0.role, $1.name.lowercased()) > ($1.role, $0.name.lowercased()) }
        names = Dictionary(users.map { ($0.id, $0.name) }) { first, _ in first }
        usersById = Dictionary(users.map { ($0.id, $0) }) { first, _ in first }
    }

    // MARK: Playing track and votes

    /// From `playChannelTrack`. The clocks can differ, so `endsAt` is placed on the local clock with the server's
    /// `syncTime` (its time when it sent the message).
    private func setTrack(_ p: JSON?) {
        voters = [:]

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
        var byVoter: [String: MyVote] = [:]

        if let dope = voting["dope"]?.int, let nope = voting["nope"]?.int {
            // Plain totals don't say who voted: keep the vote this client last sent.
            tally = Votes(dope: dope, nope: nope, star: voting["star"]?.int ?? 0, mine: playing.votes.mine)
        } else {
            for (voter, entry) in votes {
                let (dope, nope, star) = (entry["dope"]?.isOn ?? false, entry["nope"]?.isOn ?? false, entry["star"]?.isOn ?? false)
                tally.dope += dope ? 1 : 0
                tally.nope += nope ? 1 : 0
                tally.star += star ? 1 : 0
                byVoter[voter] = MyVote(dope: dope, nope: nope, star: star)
                if voter == me.id { tally.mine = MyVote(dope: dope, nope: nope, star: star) }
            }
        }

        playing.votes = tally
        nowPlaying = playing
        // Plain totals say nothing about who voted: keep what's known.
        if !byVoter.isEmpty || voting["dope"]?.int == nil { voters = byVoter }
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
                voters[me.id] = next
            }

            // The server records the star but doesn't touch the bookmark playlist; the web app adds it itself.
            if kind == .star, next.star, let uri = playing.track.uri {
                await bookmark(uri, title: playing.track.name)
            }
        } catch {
            addNotice("Vote not counted: \(error.localizedDescription)")
        }
    }

    /// A vote from the Live Activity, which may have woken the app in the background: reconnect, (re)join the
    /// activity's channel if needed, wait for the room's state, then vote.
    func voteFromOutside(_ kind: VoteKind, channelId: String, channelTitle: String) async throws {
        socket.reconnectIfNeeded()

        if channel?.id != channelId, joining?.id != channelId,
           let target = Channel(["_id": .string(channelId), "title": .string(channelTitle)]) {
            Task { await join(target) }
        }

        let deadline = Date.now.addingTimeInterval(15)
        var waited = false
        while !(isInRoom && channel?.id == channelId) {
            guard Date.now < deadline else { throw RvrbError.server("Couldn't reach RVRB to vote") }
            waited = true
            try await Task.sleep(for: .milliseconds(150))
        }

        // Just (re)joined: the server's playChannelTrack with the current votes follows the join's answer.
        if waited { try await Task.sleep(for: .milliseconds(400)) }

        let result = await addVote(kind)
        #if os(iOS)
        liveActivity.confirm(result)
        #endif
    }

    /// A vote from outside the app (the Live Activity), where the user can't see the current votes: it only ever
    /// adds one (switching between dope and nope), never takes one back. Returns what it did.
    private func addVote(_ kind: VoteKind) async -> String {
        guard let playing = nowPlaying else { return "Nothing is playing" }
        guard !isMyTurn else { return "You're playing this one" }

        let mine = playing.votes.mine
        let (already, done) = switch kind {
        case .dope: (mine.dope, "Doped")
        case .nope: (mine.nope, "Noped")
        case .star: (mine.star, "Starred")
        }
        guard !already else { return "Already \(done.lowercased())" }

        await vote(kind)

        let now = nowPlaying?.votes.mine
        let counted = switch kind {
        case .dope: now?.dope == true
        case .nope: now?.nope == true
        case .star: now?.star == true
        }
        return counted ? done : "Vote not counted"
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

    /// A moderator, admin or creator of the joined channel (its `roles`).
    var isModerator: Bool {
        guard let roles = channel?.json["roles"] else { return false }
        return ["mods", "admins", "creators"].contains { key in
            (roles[key]?.array ?? []).contains { $0.string == me.id }
        }
    }

    /// The playing DJ can skip their own track; moderators anyone's.
    var canSkip: Bool {
        nowPlaying != nil && (isMyTurn || isModerator)
    }

    func skip() async {
        guard let channel else { return }
        do {
            try await api.skip(channelId: channel.id)
        } catch {
            addNotice("Could not skip: \(error.localizedDescription)")
        }
    }

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

    /// Adds dropped or shared Spotify tracks and playlists to the queue (`position` nil: the bottom), and says
    /// what happened in the chat. Returns that message.
    @discardableResult
    func addToQueue(_ items: [SpotifyItem], at position: Int? = nil) async -> String {
        let supported = items.filter { if case .unsupported = $0 { false } else { true } }
        let unsupported = Set(items.compactMap { if case .unsupported(let kind) = $0 { kind + "s" } else { nil } })
            .sorted()

        guard !supported.isEmpty else {
            let message = unsupported.isEmpty
                ? "No Spotify tracks or playlists in what was dropped."
                : "\(unsupported.joined(separator: " and ").capitalized) can't go in the queue: add tracks or playlists."
            addNotice(message)
            return message
        }

        let message: String
        do {
            let (tracks, playlists) = try await queue.insert(supported, at: position)
            var parts: [String] = []
            if tracks.count == 1 {
                parts.append("“\(tracks[0].name)”")
            } else if !tracks.isEmpty {
                parts.append("\(tracks.count) tracks")
            }
            if playlists > 0 { parts.append(playlists == 1 ? "a playlist" : "\(playlists) playlists") }

            let place = position == 0 ? "the top of your queue" : "your queue"
            message = parts.isEmpty ? "Nothing was added (unknown tracks?)."
                : "Added \(parts.joined(separator: " and ")) to \(place)."
                + (unsupported.isEmpty ? "" : " \(unsupported.joined(separator: " and ").capitalized) were skipped.")
        } catch {
            message = "Could not add to your queue: \(error.localizedDescription)"
        }

        addNotice(message)
        return message
    }

    func loadQueue() async {
        do {
            try await queue.reload()
        } catch {
            addNotice("Could not load your queue: \(error.localizedDescription)")
        }
    }
}
