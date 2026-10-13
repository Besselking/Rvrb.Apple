import SwiftUI

/// The user's DJ queue: reorder, remove, play next, and add tracks (by search, or by dropping Spotify links between
/// rows). On the Mac the actions sit in a bar at the bottom: a sheet there has no toolbar to put them in.
struct QueueView: View {
    let client: RvrbClient

    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var notice: String?
    @State private var showsSearch = false

    private var queue: TrackQueue { client.queue }

    var body: some View {
        NavigationStack {
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
                        TrackRow(track: track, number: index + 1)
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
                } footer: {
                    if queue.total > queue.tracks.count {
                        Text("Showing the first \(queue.tracks.count) of \(queue.total) tracks.")
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
            .navigationTitle("Your Queue")
            .refreshable { perform { try await queue.reload() } }
            .task { if !queue.isLoaded { perform { try await queue.reload() } } }
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

    private func add(_ items: [SpotifyItem], at position: Int?) {
        Task {
            let message = await client.addToQueue(items, at: position)
            notice = message
            error = nil
        }
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
                        TrackRow(track: track, number: nil)
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
            }
        }
        .overlay {
            if results.isEmpty {
                if isSearching {
                    ProgressView()
                } else if query.isEmpty {
                    ContentUnavailableView("Search Spotify", systemImage: "magnifyingglass",
                                           description: Text("Tracks you pick go to the bottom of your queue."))
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
                }
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private func add(_ track: Track) {
        adding.insert(track.id)

        Task {
            defer { adding.remove(track.id) }
            do {
                try await client.queue.append([track.id])
                added.insert(track.id)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
