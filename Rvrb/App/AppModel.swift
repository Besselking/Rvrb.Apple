import Foundation
import Observation
import WebKit

/// Login state: checks the saved token at launch and creates the client once it's valid.
@Observable
final class AppModel {
    /// One per process: a Live Activity vote can launch the app in the background, before any scene exists.
    static let shared = AppModel()

    enum Phase {
        case loggedOut
        case checking
        case ready(RvrbClient)
        /// The token couldn't be checked (e.g. offline); it's kept for a retry.
        case failed(String)
    }

    let session = Session()

    init() {
        // The share extension added tracks: reload the queue if the app is running.
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in
                Task { @MainActor in await AppModel.shared.client?.loadQueue() }
            },
            QueueChangeNotification.name as CFString, nil, .deliverImmediately)
    }
    private(set) var phase: Phase = .loggedOut
    var loginMessage: String?

    var client: RvrbClient? {
        if case .ready(let client) = phase { client } else { nil }
    }

    @ObservationIgnored private var started = false

    /// Checks the saved token once per launch (from the first scene, or from a Live Activity vote).
    func start() async {
        guard !started else { return }
        started = true
        if session.token != nil { await validate() }
    }

    #if os(iOS)
    /// A vote button on the Live Activity; this may be the first thing to run after a background launch.
    func voteFromLiveActivity(_ vote: String, channelId: String, channelTitle: String) async throws {
        await start()

        // A launch that's still checking the token: wait for it.
        while case .checking = phase {
            try await Task.sleep(for: .milliseconds(100))
        }

        guard let client else { throw RvrbError.unauthorized("Open Rvrb to log in") }

        let kind: VoteKind = switch vote {
        case "dope": .dope
        case "nope": .nope
        default: .star
        }
        try await client.voteFromOutside(kind, channelId: channelId, channelTitle: channelTitle)
    }
    #endif


    func logIn(token: String) async {
        session.update(token)
        await validate()
    }

    func validate() async {
        phase = .checking
        let api = RvrbAPI(session: session)

        do {
            let login = try await api.login()
            if let token = login["token"]?.nonEmptyString { session.update(token) }
            session.persist()

            let me = Me(login["user"])
            let client = RvrbClient(api: api, session: session, me: me, chatMaxLength: login["chatMaxLength"]?.int ?? 500)
            loginMessage = nil
            phase = .ready(client)
            client.start()
        } catch RvrbError.unauthorized {
            // There's no refresh route: log in again.
            session.forget()
            loginMessage = "Your session expired. Log in again."
            phase = .loggedOut
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Leaves the channel and forgets the token on this device only. `GET /api/logout` isn't called: it would close
    /// the user's other clients too (e.g. the browser).
    func logOut() async {
        await client?.shutdown()
        session.forget()
        phase = .loggedOut

        // Forget the Spotify and RVRB web logins too, so another account can log in.
        let store = WKWebsiteDataStore.default()
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    /// Before quitting: leave the channel, or the account stays in it.
    func shutdown() async {
        await client?.shutdown()
    }
}
