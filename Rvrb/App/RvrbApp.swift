import SwiftUI

@main
struct RvrbApp: App {
    #if os(macOS)
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    #endif

    @State private var model = AppModel.shared

    init() {
        #if os(iOS)
        LiveActivityBridge.vote = { vote, channelId, channelTitle in
            try await AppModel.shared.voteFromLiveActivity(vote, channelId: channelId, channelTitle: channelTitle)
        }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .task {
                    #if os(macOS)
                    appDelegate.model = model
                    #endif
                    await model.start()
                }
        }
        #if os(macOS)
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Log Out") { Task { await model.logOut() } }
                    .disabled(model.client == nil)
            }
        }
        #endif
    }
}

#if os(macOS)
/// Sends `leave` before quitting: quitting without it left the account in the channel.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model, model.client?.channel != nil else { return .terminateNow }

        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
#endif
