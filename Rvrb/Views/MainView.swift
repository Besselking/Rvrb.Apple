import SwiftUI

/// Channels in the sidebar, the joined channel in the detail. On iPhone the split view collapses into a stack.
struct MainView: View {
    let client: RvrbClient

    @Environment(\.scenePhase) private var scenePhase
    @State private var selection: Channel?

    var body: some View {
        @Bindable var client = client

        NavigationSplitView {
            ChannelListView(client: client, selection: $selection)
                .navigationSplitViewColumnWidth(min: 240, ideal: 290, max: 400)
        } detail: {
            if selection != nil || client.channel != nil {
                RoomView(client: client)
            } else {
                ContentUnavailableView("Pick a Channel", systemImage: "music.note.house",
                                       description: Text("Join a channel to chat, vote and DJ. Its music plays on your Spotify."))
            }
        }
        .onChange(of: selection) { _, channel in
            if let channel { Task { await client.join(channel) } }
        }
        .onChange(of: client.channel == nil && client.joining == nil) { _, left in
            // Left, refused, or removed from the channel: go back to the list.
            if left { selection = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            client.setHidden(phase == .background)
            // Tracks may have been added elsewhere meanwhile (the web app, the share sheet).
            if phase == .active { Task { await client.loadQueue() } }
        }
        .alert("Couldn't Join", isPresented: Binding(get: { client.joinError != nil }, set: { if !$0 { client.joinError = nil } })) {
            Button("OK") {}
        } message: {
            Text(client.joinError ?? "")
        }
    }
}
