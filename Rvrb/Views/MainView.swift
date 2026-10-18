import SwiftUI

/// On the Mac and iPad, the user's queue in the sidebar (to manage while chatting) and the channel in the detail;
/// channels are picked in the detail when not in one, or from the room's Channels sheet. On iPhone, the channel list
/// leads to the channel, and the queue is a sheet.
struct MainView: View {
    let client: RvrbClient

    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif
    @State private var selection: Channel?

    private var queueInSidebar: Bool {
        #if os(iOS)
        sizeClass == .regular
        #else
        true
        #endif
    }

    var body: some View {
        @Bindable var client = client

        Group {
            if queueInSidebar {
                NavigationSplitView {
                    QueueView(client: client, style: .sidebar)
                        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
                } detail: {
                    if client.channel != nil || client.joining != nil {
                        RoomView(client: client, queueInSidebar: true)
                    } else {
                        ChannelListView(client: client, selection: .constant(nil), placement: .detail) { channel in
                            Task { await client.join(channel) }
                        }
                    }
                }
            } else {
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
            }
        }
        .onChange(of: selection) { _, channel in
            if let channel { Task { await client.join(channel) } }
        }
        .onChange(of: client.channel?.id) { _, id in
            // Joined without the list (rejoining on launch): show the room on iPhone too.
            if id != nil, id != selection?.id { selection = client.channel }
        }
        .onChange(of: client.channel == nil && client.joining == nil) { _, left in
            // Left, refused, or removed from the channel: go back to the list.
            if left { selection = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            client.setHidden(phase == .background)
            // Tracks may have been added elsewhere meanwhile (the web app, the share sheet).
            if phase == .active {
                Task { await client.loadQueue() }
                client.becameActive()
            }
        }
        .alert("Couldn't Join", isPresented: Binding(get: { client.joinError != nil }, set: { if !$0 { client.joinError = nil } })) {
            Button("OK") {}
        } message: {
            Text(client.joinError ?? "")
        }
        .modifier(PasswordPrompt(client: client))
    }
}

/// Asks for a private channel's password, and joins with it.
private struct PasswordPrompt: ViewModifier {
    let client: RvrbClient
    @State private var password = ""

    func body(content: Content) -> some View {
        let request = client.passwordRequest
        content
            .alert(request?.wrongPassword == true ? "Wrong Password" : "Password Required",
                   isPresented: Binding(get: { request != nil }, set: { if !$0 { client.passwordRequest = nil } }),
                   presenting: request) { request in
                SecureField("Password", text: $password)
                Button("Join") {
                    let entered = password
                    password = ""
                    Task { await client.join(request.channel, password: entered) }
                }
                .disabled(password.isEmpty)
                Button("Cancel", role: .cancel) { password = "" }
            } message: { request in
                Text(request.wrongPassword
                     ? "That isn't the password of \(request.channel.title). Try again."
                     : "\(request.channel.title) is private. Enter its password to join.")
            }
    }
}

/// Switching channels from a room when the sidebar holds the queue.
struct ChannelsSheet: View {
    let client: RvrbClient
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChannelListView(client: client, selection: .constant(nil), placement: .sheet) { channel in
                dismiss()
                if channel.id != client.channel?.id {
                    Task { await client.join(channel) }
                }
            }
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #else
            .sheetBar { Button("Done") { dismiss() }.keyboardShortcut(.cancelAction) }
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 600)
        #endif
    }
}
