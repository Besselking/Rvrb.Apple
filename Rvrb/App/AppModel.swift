import Foundation
import Observation
import WebKit

/// Login state: checks the saved token at launch and creates the client once it's valid.
@Observable
final class AppModel {
    enum Phase {
        case loggedOut
        case checking
        case ready(RvrbClient)
        /// The token couldn't be checked (e.g. offline); it's kept for a retry.
        case failed(String)
    }

    let session = Session()
    private(set) var phase: Phase = .loggedOut
    var loginMessage: String?

    var client: RvrbClient? {
        if case .ready(let client) = phase { client } else { nil }
    }

    func start() async {
        if session.token != nil { await validate() }
    }

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
