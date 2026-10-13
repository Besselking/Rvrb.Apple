import Foundation
import Observation
import os

/// JSON-RPC 2.0 over the RVRB websocket (https://app.rvrb.one/api-docs/asyncapi.yaml). Answers `keepAwake`,
/// reconnects with backoff, and hands server notifications and server requests to the client.
///
/// The `clientId` is new for every app launch: two connections with the same id bump each other off in a loop,
/// and the id only exists so that a reconnect resumes the same connection.
@Observable
final class RvrbSocket {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case waiting(retryIn: Int)
        /// The server closed this connection because the account connected from another client.
        case replaced

        var label: String {
            switch self {
            case .idle: "Not connected"
            case .connecting: "Connecting…"
            case .connected: "Connected"
            case .waiting(let seconds): "Disconnected, retrying in \(seconds)s"
            case .replaced: "Disconnected: this account connected from another client"
            }
        }
    }

    private(set) var status: Status = .idle

    /// Past the server's `ready`: requests can be sent.
    var isReady: Bool { status == .connected }

    /// `ready` arrived: (re)join the channel now.
    @ObservationIgnored var onReady: () -> Void = {}
    /// The connection dropped; the server forgets the channel until it's joined again.
    @ObservationIgnored var onDisconnect: () -> Void = {}
    /// A server notification: its method and params.
    @ObservationIgnored var onNotification: (String, JSON?) -> Void = { _, _ in }
    /// Answers server requests (`nextChannelTrack`); throw to answer with an error.
    @ObservationIgnored var requestHandler: (String, JSON?) async throws -> JSON = { method, _ in
        throw RvrbError.server("\(method) is not supported")
    }

    @ObservationIgnored let clientId = "rvrb-swift-\(UUID().uuidString.lowercased())"

    @ObservationIgnored private let session: Session
    @ObservationIgnored private let urlSession = URLSession(configuration: .default)
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextId = 0
    @ObservationIgnored private var pending: [Int: CheckedContinuation<JSON, Error>] = [:]

    init(session: Session) {
        self.session = session
    }

    func start() {
        loop?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        generation += 1
        let generation = generation
        loop = Task { await run(generation: generation) }
    }

    /// Reconnects right away when not connected (back in the foreground, or a manual retry).
    func reconnectIfNeeded() {
        if status != .connected && status != .connecting {
            start()
        }
    }

    func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        status = .idle
        failPending("Disconnected")
    }

    /// Sends a request and waits for its answer; throws on an error answer or after `timeout`.
    @discardableResult
    func request(_ method: String, _ params: JSON? = nil, timeout: Duration = .seconds(15)) async throws -> JSON {
        guard isReady else { throw RvrbError.server("Not connected") }

        nextId += 1
        let id = nextId
        var message: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method), "id": .number(Double(id))]
        message["params"] = params

        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation

            Task {
                do {
                    try await self.send(.object(message))
                } catch {
                    self.resolve(id, with: .failure(error))
                }
            }

            Task {
                try? await Task.sleep(for: timeout)
                self.resolve(id, with: .failure(RvrbError.server("No answer to \(method)")))
            }
        }
    }

    /// Sends a request without an id, for methods the server doesn't answer (`pushMessage`, `appState`).
    func notify(_ method: String, _ params: JSON? = nil) async throws {
        guard isReady else { throw RvrbError.server("Not connected") }

        var message: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
        message["params"] = params
        try await send(.object(message))
    }

    // MARK: Connection

    private func run(generation: Int) async {
        var delay = 1

        while !Task.isCancelled && generation == self.generation {
            guard let token = session.token else {
                status = .idle
                return
            }

            status = .connecting

            var components = URLComponents(string: "wss://app.rvrb.one/ws")!
            components.queryItems = [URLQueryItem(name: "token", value: token), URLQueryItem(name: "clientId", value: clientId)]
            // URLComponents leaves '+' alone in queries; a JWT has none, but be safe.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")

            let task = urlSession.webSocketTask(with: components.url!)
            task.maximumMessageSize = 16 * 1024 * 1024
            self.task = task
            task.resume()
            Log.socket.info("connecting as \(self.clientId, privacy: .public)")

            var wasReady = false
            var replaced = false

            do {
                while true {
                    let text = switch try await task.receive() {
                    case .string(let text): text
                    case .data(let data): String(decoding: data, as: UTF8.self)
                    @unknown default: ""
                    }

                    guard generation == self.generation else { return }
                    if Log.verbose { Log.socket.debug("<< \(text, privacy: .public)") }

                    switch handle(text) {
                    case .ready: wasReady = true
                    case .replaced: replaced = true
                    case .none: break
                    }
                }
            } catch {
                Log.socket.info("closed: \(error.localizedDescription, privacy: .public) (\(task.closeCode.rawValue))")
            }

            guard generation == self.generation else { return }

            self.task = nil
            failPending("Disconnected")
            onDisconnect()

            if Task.isCancelled { return }

            if replaced {
                status = .replaced
                return
            }

            if wasReady { delay = 1 }
            status = .waiting(retryIn: delay)
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private enum Event { case ready, replaced }

    private func handle(_ text: String) -> Event? {
        guard text != "pong", text != "null", let message = try? JSON(parsing: text), message.object != nil else {
            return nil
        }

        // Without a method: the answer to one of our requests.
        guard let method = message["method"]?.string else {
            guard let id = message["id"]?.int else { return nil }

            if let error = message["error"] {
                applyUpdateToken(error)
                let text = error["message"]?.string ?? error.string ?? error.text
                resolve(id, with: .failure(RvrbError.server(text)))
            } else {
                let result = message["result"] ?? .null
                applyUpdateToken(result)
                resolve(id, with: .success(result))
            }
            return nil
        }

        switch method {
        case "keepAwake":
            Task { try? await send(["jsonrpc": "2.0", "method": "stayAwake"]) }

        case "ready":
            status = .connected
            onReady()
            return .ready

        case "closed":
            if message["params"]?["reason"]?.int == 1 { return .replaced }

        default:
            // A request from the server (today only nextChannelTrack) has an id and must be answered with it.
            if let id = message["id"], id != .null {
                Task { await answer(method, id: id, params: message["params"]) }
            } else {
                onNotification(method, message["params"])
            }
        }

        return nil
    }

    private func answer(_ method: String, id: JSON, params: JSON?) async {
        var reply: [String: JSON] = ["jsonrpc": "2.0", "id": id]

        do {
            reply["result"] = try await requestHandler(method, params)
        } catch {
            reply["error"] = ["message": .string(error.localizedDescription)]
        }

        do {
            try await send(.object(reply))
        } catch {
            Log.socket.error("Could not answer \(method, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// `updateToken` is documented only as "a new session token": accept a string or an object holding one.
    private func applyUpdateToken(_ container: JSON) {
        guard let node = container["updateToken"] else { return }
        let token = node.string ?? (node["token"] ?? node["session"] ?? node["jwt"])?.string
        if let token, !token.isEmpty { session.update(token) }
    }

    private func send(_ message: JSON) async throws {
        guard let task, task.state == .running else { throw RvrbError.server("Not connected") }
        let text = message.text
        if Log.verbose { Log.socket.debug(">> \(text, privacy: .public)") }
        try await task.send(.string(text))
    }

    private func resolve(_ id: Int, with result: Result<JSON, Error>) {
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func failPending(_ reason: String) {
        let continuations = pending.values
        pending.removeAll()
        for continuation in continuations {
            continuation.resume(throwing: RvrbError.server(reason))
        }
    }
}
