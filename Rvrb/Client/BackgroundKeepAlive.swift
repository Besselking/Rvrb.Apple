#if os(iOS)
import AVFoundation
import os

/// Keeps the app running in the background, websocket and all, by playing silence: an app playing audio isn't
/// suspended. Fine for a personal build; App Review would reject it.
///
/// The session mixes with others, so it never interrupts Spotify or takes its Now Playing controls. It only runs
/// while the app is in the background in a channel, and costs battery while it does.
final class BackgroundKeepAlive {
    /// The user's choice; on by default.
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "stayConnectedInBackground") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "stayConnectedInBackground")
            if !newValue { stop() }
        }
    }

    private(set) var isRunning = false

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    /// A fixed format: the mixer's output format isn't known (sample rate 0) until the session is active.
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
    private var observers: [NSObjectProtocol] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        let center = NotificationCenter.default
        // A phone call or another app's non-mixable audio stops the engine; start again when it's over.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            guard type == .ended else { return }
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    func start() {
        guard isEnabled else {
            Log.app.info("Not staying connected in the background: turned off")
            return
        }
        guard !isRunning else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)

            guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate)) else {
                Log.app.error("Could not make the silence buffer")
                stop()
                return
            }
            silence.frameLength = silence.frameCapacity // Zeroed: one second of silence, looped.

            try engine.start()
            player.scheduleBuffer(silence, at: nil, options: .loops)
            player.play()
            isRunning = true
            Log.app.info("Keeping the connection alive in the background")
        } catch {
            Log.app.error("Could not start background audio: \(error.localizedDescription, privacy: .public)")
            stop()
        }
    }

    func stop() {
        guard isRunning || engine.isRunning else { return }
        player.stop()
        engine.stop()
        isRunning = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func restart() {
        guard isRunning else { return }
        isRunning = false
        start()
    }
}
#endif
