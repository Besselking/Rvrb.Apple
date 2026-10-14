import Foundation

struct ChatMessage: Identifiable {
    enum Kind {
        case chat
        case whisper
        /// Server announcements, e.g. "… is being played for the first time!".
        case alert
        /// A track started ("Artist::Title").
        case play
        case bot
        /// This app's own notices.
        case notice
    }

    let id: String
    let time: Date
    let userId: String?
    let name: String
    let kind: Kind
    let body: ChatText.Body
    let isMine: Bool
    let mentionsMe: Bool
    /// The sender's picture as the message carries it, for senders no longer in the channel.
    var avatarURL: URL? = nil
    /// The server's time for it (epoch ms): with the channel, what names a message. nil for this app's notices.
    var syncTime: Double? = nil
    /// The `syncTime` of the message this one answers.
    var replyTo: Double? = nil

    /// Messages people wrote can be answered (as in the web app).
    var canReply: Bool {
        syncTime != nil && [.chat, .whisper, .bot].contains(kind)
    }
}

/// What a user is doing, shown on their avatar.
enum UserActivity {
    case listening
    /// Playing the current track (the first DJ).
    case djing
    case doped
    case noped
}

/// The votes on the playing track, and the user's own.
struct Votes: Equatable {
    var dope = 0
    var nope = 0
    var star = 0
    var mine = MyVote()
}

struct MyVote: Equatable {
    var dope = false
    var nope = false
    var star = false
}

struct NowPlaying {
    let track: Track
    /// When the track started, on the local clock.
    let start: Date
    var votes = Votes()

    var end: Date { start.addingTimeInterval(track.duration) }
}

enum VoteKind {
    case dope, nope, star
}
