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
}

/// What a user is doing, shown on their avatar.
enum UserActivity {
    case listening
    /// On the decks (the first DJ is playing).
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
