#if os(iOS)
import ActivityKit
import Foundation
import Observation
import os
import UIKit

/// Mirrors the joined channel's playing track into a Live Activity. RVRB sends no pushes for it, so it's only
/// updated while the app runs; once the app is suspended the progress still runs to the end of the track, after
/// which the activity is stale until the app is opened (or a vote button wakes it).
final class LiveActivityController {
    private typealias State = RvrbActivityAttributes.ContentState

    private unowned let client: RvrbClient
    /// The running activity, by id: `Activity` isn't Sendable, so it's looked up again where it's used.
    private var activityId: String?
    private var lastState: State?
    private var artwork: (url: URL, data: Data?)?
    private var syncing = false
    private var needsSync = false

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "liveActivityEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "liveActivityEnabled")
            sync()
        }
    }

    /// The running activity's channel: after a relaunch in the background, the channel to rejoin.
    var channel: Channel? {
        guard let activityId, let attributes = Self.activity(activityId)?.attributes else { return nil }
        return Channel(["_id": .string(attributes.channelId), "title": .string(attributes.channelTitle)])
    }

    init(client: RvrbClient) {
        self.client = client
    }

    func start() {
        // Activities outlive the app: adopt one left from a previous launch, end any others.
        let existing = Activity<RvrbActivityAttributes>.activities.map(\.id)
        activityId = existing.first
        for extra in existing.dropFirst() {
            Task { await Self.end(id: extra) }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = (client.channel, client.nowPlaying?.track.id, client.nowPlaying?.votes, client.djIds, client.users)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        sync()
    }

    /// Coalesces bursts of changes (joining sends the track, DJs and users at once).
    private func sync() {
        needsSync = true
        guard !syncing else { return }
        syncing = true

        Task {
            while needsSync {
                needsSync = false
                await apply()
            }
            syncing = false
        }
    }

    private func apply() async {
        guard isEnabled, let channel = client.channel, let playing = client.nowPlaying else {
            await end()
            return
        }

        let track = playing.track
        let dj = client.djIds.first.map { client.name(for: $0) }
        let state = State(track: track.name, artists: track.artists, dj: dj,
                          start: playing.start, end: playing.end,
                          dope: playing.votes.dope, nope: playing.votes.nope, star: playing.votes.star,
                          myDope: playing.votes.mine.dope, myNope: playing.votes.mine.nope, myStar: playing.votes.mine.star,
                          isMyTrack: client.isMyTurn,
                          artwork: await thumbnail(track.artworkURL(minWidth: 64)))

        // Stale a little after the track ends, unless an update for the next track arrives first.
        let content = ActivityContent(state: state, staleDate: playing.end.addingTimeInterval(5))

        if let activityId, let activity = Self.activity(activityId),
           activity.attributes.channelId == channel.id, activity.activityState == .active {
            guard state != lastState else { return }
            await Self.update(id: activityId, content)
            lastState = state
            return
        }

        await end()

        // Starting needs the app in the foreground; updates don't.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background else { return }

        do {
            activityId = try Activity.request(
                attributes: RvrbActivityAttributes(channelId: channel.id, channelTitle: channel.title),
                content: content).id
            lastState = state
        } catch {
            Log.app.error("Could not start the Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end() async {
        guard let activityId else { return }
        self.activityId = nil
        lastState = nil
        await Self.end(id: activityId)
    }

    private static func activity(_ id: String) -> Activity<RvrbActivityAttributes>? {
        Activity<RvrbActivityAttributes>.activities.first { $0.id == id }
    }

    private nonisolated static func update(id: String, _ content: ActivityContent<State>) async {
        await Activity<RvrbActivityAttributes>.activities.first { $0.id == id }?.update(content)
    }

    private nonisolated static func end(id: String) async {
        await Activity<RvrbActivityAttributes>.activities.first { $0.id == id }?.end(nil, dismissalPolicy: .immediate)
    }

    /// A small JPEG of the album art. The whole state must stay under 4 KB, so it shrinks until it fits.
    private func thumbnail(_ url: URL?) async -> Data? {
        guard let url else { return nil }
        if let artwork, artwork.url == url { return artwork.data }

        var result: Data?
        if let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) {
            search: for side in [120.0, 96, 72, 56] {
                guard let small = await image.byPreparingThumbnail(ofSize: CGSize(width: side, height: side)) else { continue }
                for quality in [0.7, 0.5, 0.35] {
                    if let jpeg = small.jpegData(compressionQuality: quality), jpeg.count <= 2400 {
                        result = jpeg
                        break search
                    }
                }
            }
        }

        artwork = (url, result)
        return result
    }
}
#endif
