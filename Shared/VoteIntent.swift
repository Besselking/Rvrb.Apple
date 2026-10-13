#if os(iOS)
import AppIntents
import Foundation

/// A vote button on the Live Activity. A `LiveActivityIntent` runs in the app's process (waking it in the
/// background if needed), so the app can reconnect and vote; the widget extension only draws the button.
struct VoteIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Vote on the Playing Track"
    static let isDiscoverable = false

    /// "dope", "nope" or "star".
    @Parameter(title: "Vote") var vote: String
    @Parameter(title: "Channel") var channelId: String
    @Parameter(title: "Channel Title") var channelTitle: String

    init() {}

    init(vote: String, channelId: String, channelTitle: String) {
        self.vote = vote
        self.channelId = channelId
        self.channelTitle = channelTitle
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await LiveActivityBridge.vote?(vote, channelId, channelTitle)
        return .result()
    }
}

/// Set by the app at launch; nil in the widget extension.
enum LiveActivityBridge {
    static var vote: ((_ vote: String, _ channelId: String, _ channelTitle: String) async throws -> Void)?
}
#endif
