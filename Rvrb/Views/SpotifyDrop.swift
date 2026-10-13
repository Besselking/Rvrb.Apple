import CoreTransferable
import Foundation

/// What Spotify puts on the pasteboard when dragging tracks or playlists: links as text (one per line for several)
/// or as a URL. Text comes first: a URL representation may carry only the first of several links.
nonisolated struct SpotifyDrop: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(importing: { (text: String) in SpotifyDrop(text: text) })
        ProxyRepresentation(importing: { (url: URL) in SpotifyDrop(text: url.absoluteString) })
    }

    static func items(in drops: [SpotifyDrop]) -> [SpotifyItem] {
        SpotifyLinks.items(in: drops.map(\.text).joined(separator: "\n"))
    }
}
