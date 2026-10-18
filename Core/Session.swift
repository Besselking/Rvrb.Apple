import Foundation
import Observation
import os
import Security

/// Holds the RVRB session JWT and keeps it in the keychain, so logging in through Spotify is needed once.
/// The server can hand out a refreshed token at any time (REST `update-token` header, websocket `updateToken`);
/// `update(_:)` stores it.
@Observable
final class Session {
    private(set) var token: String?
    /// The server says the login is no good any more (see `RvrbError.endsSpotifyLogin`), with its message.
    @ObservationIgnored var onLoginLost: ((String) -> Void)?

    init() {
        // RVRB_TOKEN in the scheme's environment wins, for development.
        if let token = ProcessInfo.processInfo.environment["RVRB_TOKEN"], !token.isEmpty {
            self.token = token
        } else {
            token = Keychain.read()
        }
    }

    func update(_ token: String) {
        guard token != self.token else { return }
        self.token = token
        Keychain.write(token)
    }

    /// Saves the token again, into the keychain group shared with the share extension (moving a token saved
    /// before that group existed).
    func persist() {
        if let token { Keychain.write(token) }
    }

    func loginLost(_ message: String) {
        onLoginLost?(message)
    }

    func forget() {
        token = nil
        Keychain.delete()
    }

    /// Accepts a bare JWT, a "Bearer ..." header value, or the whole `/login/?session=...` URL the login redirects to.
    static func parsePastedToken(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)

        if let range = text.range(of: "session=") {
            let rest = text[range.upperBound...]
            text = String(rest.prefix { $0 != "&" && $0 != "#" }).removingPercentEncoding ?? String(rest)
        }

        if text.lowercased().hasPrefix("bearer ") {
            text = String(text.dropFirst("bearer ".count))
        }

        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n\t"))
        return text.isEmpty ? nil : text
    }
}

/// The token as a generic password. On macOS this is the login keychain, which works in the sandbox without a
/// keychain access group (and so without a development team). On iOS it goes in the App Group, which doubles as a
/// keychain access group, so the share extension can read it; without that entitlement, in the app's own group.
private enum Keychain {
    #if os(iOS)
    static let sharedGroup = "group.is.bes.Rvrb"
    #endif

    private static let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Rvrb",
        kSecAttrAccount as String: "session",
    ]

    static func read() -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ token: String) {
        // Replace rather than update: an older item may sit in another access group.
        SecItemDelete(query as CFDictionary)

        var item = query
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        #if os(iOS)
        var shared = item
        shared[kSecAttrAccessGroup as String] = sharedGroup
        if SecItemAdd(shared as CFDictionary, nil) == errSecSuccess { return }
        #endif

        let added = SecItemAdd(item as CFDictionary, nil)
        if added != errSecSuccess { Log.app.error("Could not save the token: \(added)") }
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

nonisolated enum Log {
    static let app = Logger(subsystem: "Rvrb", category: "app")
    static let socket = Logger(subsystem: "Rvrb", category: "socket")

    /// With RVRB_DEBUG set (see the scheme), every websocket frame is logged, as the notes recommend.
    static let verbose = ProcessInfo.processInfo.environment["RVRB_DEBUG"].map { !$0.isEmpty } ?? false
}
