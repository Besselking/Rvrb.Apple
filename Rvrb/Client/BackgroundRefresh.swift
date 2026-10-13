#if os(iOS)
import BackgroundTasks
import Foundation
import os

/// Background App Refresh: while the app is in the background with a channel joined, iOS is asked to wake it
/// when the playing track ends, to reconnect and bring the Live Activity up to date. iOS decides when (and
/// whether) that happens, based on how the app is used, battery and the Background App Refresh setting; a wake
/// gives about 30 seconds.
enum BackgroundRefresh {
    /// Also listed under BGTaskSchedulerPermittedIdentifiers in Config/Rvrb-iOS-Info.plist.
    static let identifier = "com.marijn.Rvrb.refresh"

    static func schedule(after date: Date?) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // Not sooner than a minute from now: iOS throttles apps that ask for too much.
        request.earliestBeginDate = max(date ?? .now.addingTimeInterval(15 * 60), .now.addingTimeInterval(60))

        do {
            try BGTaskScheduler.shared.submit(request)
            Log.app.info("Background refresh requested for \(request.earliestBeginDate!, privacy: .public)")
        } catch {
            // Fails in the simulator before iOS 26 and when Background App Refresh is off.
            Log.app.error("Could not schedule a background refresh: \(error.localizedDescription, privacy: .public)")
        }
    }

    static func cancel() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
    }
}
#endif
