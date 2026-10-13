import Foundation
import Observation

/// Plays the channel's tracks on one of the user's Spotify Connect devices. RVRB streams no audio: it drives
/// Spotify with the login it keeps for the user, so the client only sends `playTrack` (the track and an optional
/// device) and `pauseTrack`. Without a device the server picks one: active, preferred, any, or the web player.
@Observable
final class Player {
    /// Whether the channel's tracks are played on Spotify. Saved between launches.
    private(set) var isEnabled = UserDefaults.standard.object(forKey: "playbackEnabled") as? Bool ?? true

    /// The device to play on, or nil to let the server choose.
    private(set) var deviceId: String?
    private(set) var deviceName: String?

    @ObservationIgnored var onError: (String) -> Void = { _ in }

    @ObservationIgnored private let socket: RvrbSocket
    @ObservationIgnored private var uri: String?
    @ObservationIgnored private var playingURI: String?

    init(socket: RvrbSocket) {
        self.socket = socket
    }

    /// `playChannelTrack`: play it, unless the server already did (`playTrack: false`, for mobile clients).
    func channelTrack(uri: String?, serverPlays: Bool) async {
        self.uri = uri

        if serverPlays {
            playingURI = uri
        } else if isEnabled, uri != nil, uri != playingURI {
            // After a reconnect the server sends the same track again; don't restart it.
            await play()
        }
    }

    /// `pauseChannelTrack`, or leaving the channel: nothing is playing any more.
    func stop() async {
        uri = nil
        if playingURI != nil { await pause() }
    }

    func setEnabled(_ enabled: Bool) async {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "playbackEnabled")

        if enabled, uri != nil {
            await play()
        } else if !enabled, playingURI != nil {
            await pause()
        }
    }

    /// Switches device; the playing track continues there at the channel's position.
    func use(_ device: Device?) async {
        deviceId = device?.id
        deviceName = device?.name
        if isEnabled, uri != nil { await play() }
    }

    /// Plays the channel's track again from its current position (e.g. after pausing Spotify by hand).
    func resync() async {
        if isEnabled, uri != nil { await play() }
    }

    /// `activePlayer`: playback went to this device.
    func activePlayer(deviceId: String?) {
        guard let deviceId, deviceId != self.deviceId else { return }
        self.deviceId = deviceId
        deviceName = nil
    }

    private func play() async {
        guard let uri else { return }
        var params: [String: JSON] = ["uri": .string(uri)]
        if let deviceId { params["device_id"] = .string(deviceId) }

        do {
            try await socket.request("playTrack", .object(params))
            playingURI = uri
        } catch {
            playingURI = nil
            onError(error.localizedDescription)
        }
    }

    private func pause() async {
        playingURI = nil
        do {
            try await socket.request("pauseTrack", timeout: .seconds(3))
        } catch {
            onError(error.localizedDescription)
        }
    }
}
