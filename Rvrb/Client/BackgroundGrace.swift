#if os(iOS)
import os
import UIKit

/// A "don't suspend me yet" assertion: keeps the app (and so the websocket) running for a short while after it
/// goes to the background, so switching to Spotify and back doesn't drop the connection. iOS decides how long,
/// typically around 30 seconds and never guaranteed; when it runs out the assertion is ended and the app suspends.
final class BackgroundGrace {
    private let name: String
    private var task: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        self.name = name
    }

    func begin() {
        guard task == .invalid else { return }
        task = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Must end promptly, or the watchdog kills the app.
            Log.app.info("Background time ran out")
            self?.end()
        }
    }

    func end() {
        guard task != .invalid else { return }
        UIApplication.shared.endBackgroundTask(task)
        task = .invalid
    }
}
#endif
