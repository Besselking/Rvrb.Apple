#if os(iOS)
import ActivityKit
import Foundation
import Observation
import os
import UIKit

/// Keeps a Live Activity for the joined channel: started when joining (with the app in the foreground), ended
/// on leaving. It holds no track details, so it needs no updates while the app sleeps; a vote from it briefly
/// shows what it did.
final class LiveActivityController {
    private typealias State = RvrbActivityAttributes.ContentState

    private unowned let client: RvrbClient
    /// The running activity, by id: `Activity` isn't Sendable, so it's looked up again where it's used.
    private var activityId: String?
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

    /// Shows what a vote from the activity did, for a few seconds.
    func confirm(_ text: String) {
        guard let activityId else { return }
        let content = ActivityContent(state: State(confirmation: text), staleDate: .now.addingTimeInterval(8))
        Task { await Self.update(id: activityId, content) }
    }

    private func observe() {
        withObservationTracking {
            _ = client.channel
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        sync()
    }

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
        guard isEnabled, let channel = client.channel else {
            await end()
            return
        }

        if let activityId, let activity = Self.activity(activityId),
           activity.attributes.channelId == channel.id, activity.activityState == .active {
            return
        }

        await end()

        // Starting needs the app in the foreground.
        guard ActivityAuthorizationInfo().areActivitiesEnabled,
              UIApplication.shared.applicationState != .background else { return }

        do {
            activityId = try Activity.request(
                attributes: RvrbActivityAttributes(channelId: channel.id, channelTitle: channel.title),
                content: ActivityContent(state: State(confirmation: nil), staleDate: nil)).id
        } catch {
            Log.app.error("Could not start the Live Activity: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func end() async {
        guard let activityId else { return }
        self.activityId = nil
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
}
#endif
