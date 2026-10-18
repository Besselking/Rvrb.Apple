import Foundation
import Observation

/// The user's DJ queue: the stack marked `activeQueue` (created when there is none). While the user DJs, the server
/// asks for the next track (`nextChannelTrack`); the client answers with the top and takes it off once it plays,
/// unless the server already has (it says so with `refreshDjStack`). The queue is kept in memory so that question
/// can be answered within 2.5 s.
@Observable
final class TrackQueue {
    /// The most the server returns per request.
    static let pageSize = 50

    /// The tracks loaded so far, top first: a page of 50 at a time, more as the list is scrolled (`loadMore()`).
    private(set) var tracks: [Track] = []
    /// All tracks, including those not loaded yet.
    private(set) var total = 0
    private(set) var isLoaded = false
    private(set) var isLoadingMore = false

    var hasMore: Bool { tracks.count < total }

    /// Pages loaded; a reload after a change loads as many again, so the list doesn't shrink under the user.
    @ObservationIgnored private var loadedPages = 1

    var next: Track? { tracks.first }

    @ObservationIgnored private let api: RvrbAPI
    @ObservationIgnored private var stackId: String?
    @ObservationIgnored private var tail: Task<Void, Never>?

    init(api: RvrbAPI) {
        self.api = api
    }

    /// Loads the next page, when there is one.
    func loadMore() async throws {
        guard hasMore, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }

        try await serialized {
            guard self.hasMore else { return }
            let page = try await self.api.stack(id: try await self.resolveStackId(), page: self.loadedPages,
                                                limit: Self.pageSize)
            self.tracks += (page["tracks"]?.array ?? []).compactMap(Track.init)
            self.total = page["totalItems"]?.int ?? self.tracks.count
            self.loadedPages += 1
        }
    }

    func reload() async throws {
        try await serialized { try await self.reloadNow() }
    }

    /// Adds tracks at the bottom (the server's default position is the top).
    func append(_ trackIds: [String]) async throws {
        try await change { try await self.api.addTracks(stackId: $0, trackIds: trackIds, position: self.total) }
    }

    /// Adds dropped or shared Spotify tracks and playlists at `position`, or at the bottom when nil.
    @discardableResult
    func insert(_ items: [SpotifyItem], at position: Int?) async throws -> (tracks: [Track], playlists: Int) {
        var result: (tracks: [Track], playlists: Int) = ([], 0)
        try await change { result = try await self.api.add(items, toStack: $0, at: position) }
        return result
    }

    func shuffle() async throws {
        try await change { try await self.api.shuffleStack(id: $0) }
    }

    func remove(at position: Int) async throws {
        try await change { try await self.api.removeTrack(stackId: $0, at: position) }
    }

    /// Moves a track; `target` is its position after the move.
    func move(from position: Int, to target: Int) async throws {
        guard position != target else { return }
        try await change { try await self.api.moveTrack(stackId: $0, from: position, to: target) }
    }

    /// Takes a track that just started playing off the top. Reloads first and only removes the top if it is still
    /// that track, so a track someone else already removed isn't followed by the wrong one.
    /// `queueLength` is the length when the track was handed to the server: a shorter queue means the server took
    /// it off already, and removing the top would take the next track too (the same song queued twice in a row).
    func removePlayed(trackId: String, queueLength: Int) async throws {
        try await serialized {
            try await self.reloadNow()
            guard self.next?.id == trackId, self.total >= queueLength else { return }
            try await self.api.removeTrack(stackId: try await self.resolveStackId(), at: 0)
            try await self.reloadNow()
        }
    }

    private func change(_ operation: @escaping (String) async throws -> Void) async throws {
        try await serialized {
            do {
                try await operation(try await self.resolveStackId())
            } catch {
                // Reload anyway, so the list shows what the server has.
                try? await self.reloadNow()
                throw error
            }
            try await self.reloadNow()
        }
    }

    /// Runs queue operations one at a time: positions are only meaningful against the list they were taken from.
    private func serialized(_ operation: @escaping () async throws -> Void) async throws {
        let previous = tail
        let task = Task<Void, Error> {
            await previous?.value
            try await operation()
        }
        tail = Task { _ = await task.result }
        try await task.value
    }

    /// Loads the pages loaded so far again (at least the first).
    private func reloadNow() async throws {
        let stackId = try await resolveStackId()
        var loaded: [Track] = []
        var count = 0
        var pages = 0

        for page in 0..<max(1, loadedPages) {
            let result = try await api.stack(id: stackId, page: page, limit: Self.pageSize)
            let pageTracks = (result["tracks"]?.array ?? []).compactMap(Track.init)
            loaded += pageTracks
            count = result["totalItems"]?.int ?? loaded.count
            pages = page + 1
            if pageTracks.count < Self.pageSize || loaded.count >= count { break }
        }

        tracks = loaded
        total = count
        loadedPages = pages
        isLoaded = true
    }

    private func resolveStackId() async throws -> String {
        if let stackId { return stackId }

        let id = try await api.djQueueId()
        stackId = id
        return id
    }
}
