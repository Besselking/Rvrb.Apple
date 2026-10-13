#if os(iOS)
import ActivityKit
import Foundation

/// The Live Activity for the channel's playing track (Lock Screen, Notification Center, Dynamic Island).
/// Shared by the app, which starts and updates it, and the widget extension, which draws it.
nonisolated struct RvrbActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var track: String
        var artists: String
        var dj: String?
        /// The track's start and end on the local clock; the progress runs from these without updates.
        var start: Date
        var end: Date
        var dope: Int
        var nope: Int
        var star: Int
        var myDope: Bool
        var myNope: Bool
        var myStar: Bool
        /// The user is playing this track (voting on it would fail).
        var isMyTrack: Bool
        /// A small JPEG: widgets can't load images from the network, and the state must stay under 4 KB.
        var artwork: Data?
    }

    var channelId: String
    var channelTitle: String
}
#endif
