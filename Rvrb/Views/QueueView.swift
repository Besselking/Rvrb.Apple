import SwiftUI

/// The user's DJ queue: reorder, remove, play next, and add tracks (by search, or by dropping Spotify links between
/// rows). A sheet on iPhone; on the Mac and iPad it's the sidebar, there to manage while chatting. On the Mac and in
/// the sidebar the actions sit in a bar at the bottom (a Mac sheet has no toolbar to put them in).
struct QueueView: View {
    enum Style { case sheet, sidebar }

    let client: RvrbClient
    var style: Style = .sheet

    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    /// ISRCs never played on RVRB.
    @State private var unplayed: Set<String> = []
    @State private var notice: String?
    @State private var showsSearch = false

    private var queue: TrackQueue { client.queue }

    var body: some View {
        switch style {
        case .sheet: sheet
        case .sidebar: sidebar
        }
    }

    private var sidebar: some View {
        list
            .navigationTitle("Your Queue")
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Button("Add Tracks", systemImage: "plus") { showsSearch = true }
                        shuffleButton
                            .labelStyle(.iconOnly)
                        Spacer()
                        #if os(iOS)
                        EditButton()
                        #endif
                    }
                    .padding(12)
                }
                .background(.bar)
            }
            .sheet(isPresented: $showsSearch) {
                SearchSheet(client: client)
            }
    }

    private var sheet: some View {
        NavigationStack {
            list
                .navigationTitle("Your Queue")
                #if os(iOS)
                .navigationDestination(isPresented: $showsSearch) {
                    SearchView(client: client)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add Tracks", systemImage: "plus") { showsSearch = true }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        shuffleButton
                    }
                    ToolbarItem(placement: .topBarLeading) {
                        EditButton()
                    }
                }
                #else
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        HStack {
                            Button("Add Tracks…", systemImage: "plus") { showsSearch = true }
                            shuffleButton
                            Text("or drag them in from Spotify")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Done") { dismiss() }
                                .keyboardShortcut(.defaultAction)
                        }
                        .padding(12)
                    }
                    .background(.bar)
                }
                .sheet(isPresented: $showsSearch) {
                    SearchSheet(client: client)
                }
                #endif
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 560)
        #endif
    }

    private var list: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            if let notice {
                Label(notice, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
            }

            Section {
                ForEach(Array(queue.tracks.enumerated()), id: \.offset) { index, track in
                    let playsAgo = client.playsAgo(track)
                    // Playing now on someone else's turn: they "sniped" it.
                    let sniper = playsAgo == 0 ? client.djIds.first.flatMap { $0 == client.me.id ? nil : client.name(for: $0) } : nil
                    TrackRow(track: track, number: index + 1, isFirstPlay: track.isrc.map(unplayed.contains) ?? false,
                             playsAgo: playsAgo, playingBy: sniper)
                        // Playing now, or just played in the channel: probably not one to play again soon.
                        .listRowBackground(playsAgo == 0 ? Color.accentColor.opacity(0.16)
                                           : playsAgo != nil ? Color.orange.opacity(0.12) : nil)
                        .onAppear {
                            // Near the end of what's loaded: load the next 50.
                            if index >= queue.tracks.count - 10, queue.hasMore {
                                perform { try await queue.loadMore() }
                            }
                        }
                        .contextMenu {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                perform { try await queue.move(from: index, to: 0) }
                            }
                            .disabled(index == 0)
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                perform { try await queue.remove(at: index) }
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                perform { try await queue.remove(at: index) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                                perform { try await queue.move(from: index, to: 0) }
                            }
                            .tint(.accentColor)
                        }
                }
                .onMove { offsets, destination in
                    guard let from = offsets.first else { return }
                    // SwiftUI counts the destination before the removal; the server after it.
                    let target = destination > from ? destination - 1 : destination
                    perform { try await queue.move(from: from, to: target) }
                }
                .dropDestination(for: SpotifyDrop.self) { drops, index in
                    add(SpotifyDrop.items(in: drops), at: index)
                }
            } header: {
                #if os(macOS)
                // A Mac sidebar shows no title of its own.
                if style == .sidebar {
                    Text(queue.total > 0 ? "Your Queue (\(queue.total))" : "Your Queue")
                }
                #endif
            } footer: {
                if queue.hasMore {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("\(queue.total - queue.tracks.count) more tracks")
                    }
                } else if client.isDJ {
                    Text("The top track plays on your next turn.")
                }
            }
        }
        .overlay {
            if queue.isLoaded && queue.tracks.isEmpty {
                ContentUnavailableView {
                    Label("Your Queue Is Empty", systemImage: "music.note.list")
                } description: {
                    Text("Add tracks to play them when you DJ.")
                } actions: {
                    Button("Add Tracks") { showsSearch = true }
                }
            } else if !queue.isLoaded {
                ProgressView()
            }
        }
        // Dropped anywhere else (say on an empty queue): the bottom.
        .dropDestination(for: SpotifyDrop.self) { drops, _ in
            add(SpotifyDrop.items(in: drops), at: nil)
            return true
        }
        .refreshable { perform { try await queue.reload() } }
        // Always fresh: tracks can be added from the web app or the share sheet.
        .task { perform { try await queue.reload() } }
        .task(id: queue.tracks.compactMap(\.isrc)) {
            unplayed = (try? await client.api.unplayed(isrcs: queue.tracks.compactMap(\.isrc))) ?? unplayed
        }
    }

    private func add(_ items: [SpotifyItem], at position: Int?) {
        Task {
            let message = await client.addToQueue(items, at: position)
            notice = message
            error = nil
        }
    }

    private var shuffleButton: some View {
        Button("Shuffle", systemImage: "shuffle") {
            perform { try await queue.shuffle() }
        }
        .disabled(queue.total < 2)
        .help("Put your queue in random order")
    }

    private func perform(_ operation: @escaping () async throws -> Void) {
        Task {
            do {
                try await operation()
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Spotify track search; picking a result adds it to the bottom of the queue.
struct SearchView: View {
    let client: RvrbClient

    @State private var query = ""
    @State private var results: [Track] = []
    @State private var added: Set<String> = []
    @State private var adding: Set<String> = []
    @State private var isSearching = false
    @State private var error: String?
    @State private var unplayed: Set<String> = []

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
            }

            ForEach(results) { track in
                Button {
                    add(track)
                } label: {
                    HStack {
                        TrackRow(track: track, number: nil, isFirstPlay: track.isrc.map(unplayed.contains) ?? false)
                        Spacer()
                        if adding.contains(track.id) {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: added.contains(track.id) ? "checkmark.circle.fill" : "plus.circle")
                                .font(.title3)
                                .foregroundStyle(added.contains(track.id) ? Color.green : Color.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(added.contains(track.id) || adding.contains(track.id))
                .contextMenu {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        add(track, next: true)
                    }
                    Button("Add to Queue", systemImage: "text.badge.plus") { add(track) }
                }
                .swipeActions(edge: .leading) {
                    Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") {
                        add(track, next: true)
                    }
                    .tint(.accentColor)
                }
                .swipeActions(edge: .trailing) {
                    Button("Add to Queue", systemImage: "text.badge.plus") { add(track) }
                        .tint(.green)
                }
            }
        }
        .overlay {
            if results.isEmpty {
                if isSearching {
                    ProgressView()
                } else if query.isEmpty {
                    ContentUnavailableView("Search Spotify", systemImage: "magnifyingglass",
                                           description: Text(Self.hint))
                } else if error == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
        }
        .navigationTitle("Add Tracks")
        #if os(macOS)
        // A Mac sheet has no toolbar for .searchable.
        .safeAreaInset(edge: .top, spacing: 0) {
            TextField("Search Spotify: songs, artists, albums", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(12)
        }
        #else
        .searchable(text: $query, prompt: "Songs, artists, albums")
        #endif
        .task(id: query) {
            let search = query.trimmingCharacters(in: .whitespaces)
            guard !search.isEmpty else {
                results = []
                return
            }

            try? await Task.sleep(for: .milliseconds(350))
            if Task.isCancelled { return }

            isSearching = true
            defer { isSearching = false }

            do {
                let tracks = try await client.api.searchTracks(search)
                if !Task.isCancelled {
                    results = tracks
                    error = nil
                    unplayed = (try? await client.api.unplayed(isrcs: tracks.compactMap(\.isrc))) ?? []
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// How to add, per platform.
    private static var hint: String {
        #if os(macOS)
        "Click a track to add it to the bottom of your queue, or right-click it to play it next."
        #else
        "Tap a track to add it to the bottom of your queue. Swipe right or touch and hold it to play it next."
        #endif
    }

    /// Adds at the bottom of the queue, or with `next` at the top (it plays on the next turn).
    private func add(_ track: Track, next: Bool = false) {
        adding.insert(track.id)

        Task {
            defer { adding.remove(track.id) }
            do {
                if next {
                    try await client.queue.insert([.track(id: track.id)], at: 0)
                } else {
                    try await client.queue.append([track.id])
                }
                added.insert(track.id)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
