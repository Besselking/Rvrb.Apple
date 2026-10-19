#if os(iOS)
import ActivityKit
import Foundation

/// The Live Activity for the joined channel (Lock Screen, Notification Center, Dynamic Island): its name and vote
/// buttons. It shows nothing about the playing track: the app sleeps in the background (RVRB carries on
/// server-side), so track details and vote counts would go stale. Shared by the app, which starts it, and the
/// widget extension, which draws it.
nonisolated struct RvrbActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        /// What a vote from the activity did ("Doped", "Already favorited", …); shown until the content goes stale
        /// a few seconds later.
        var confirmation: String?
    }

    var channelId: String
    var channelTitle: String
}
#endif
