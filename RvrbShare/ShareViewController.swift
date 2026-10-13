import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Rvrb" in the share sheet (e.g. Spotify's Share → Rvrb): adds the shared tracks or playlists to the user's DJ
/// queue. Uses the token the app keeps in the shared keychain group, so the app must have been logged in once.
@objc(ShareViewController)
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)

        Task { await model.load() }
    }
}

@Observable
final class ShareModel {
    enum Phase {
        case loading
        case needsLogin
        case nothing(String)
        case ready
        case adding
        case done(String)
        case failed(String)
    }

    private(set) var phase: Phase = .loading
    /// The tracks and playlists to add, in the order shared.
    private(set) var items: [SpotifyItem] = []
    private(set) var skipped: [String] = []
    private(set) var previews: [SpotifyItem: SpotifyPreview] = [:]

    @ObservationIgnored private let context: NSExtensionContext?
    @ObservationIgnored private let session = Session()

    init(context: NSExtensionContext?) {
        self.context = context
    }

    func load() async {
        let found = SpotifyLinks.items(in: await sharedText())
        items = found.filter { if case .unsupported = $0 { false } else { true } }
        skipped = Set(found.compactMap { if case .unsupported(let kind) = $0 { kind + "s" } else { nil } }).sorted()

        if items.isEmpty {
            phase = .nothing(skipped.isEmpty
                ? "There's no Spotify track or playlist in what was shared."
                : "\(skipped.joined(separator: " and ").capitalized) can't go in the queue. Share a track or a playlist.")
            return
        }

        guard session.token != nil else {
            phase = .needsLogin
            return
        }

        phase = .ready

        for item in items.prefix(20) {
            if let link = item.link, let preview = await SpotifyPreview.load(link) {
                previews[item] = preview
            }
        }
    }

    func add(playNext: Bool) async {
        phase = .adding
        let api = RvrbAPI(session: session)

        do {
            let queue = try await api.djQueueId()
            let (tracks, playlists) = try await api.add(items, toStack: queue, at: playNext ? 0 : nil)

            var parts: [String] = []
            if tracks.count == 1 {
                parts.append("“\(tracks[0].name)”")
            } else if !tracks.isEmpty {
                parts.append("\(tracks.count) tracks")
            }
            if playlists > 0 { parts.append(playlists == 1 ? "a playlist" : "\(playlists) playlists") }

            phase = .done(parts.isEmpty
                ? "Nothing was added."
                : "Added \(parts.joined(separator: " and ")) to \(playNext ? "the top of your queue" : "your queue").")

            try? await Task.sleep(for: .seconds(1.2))
            close()
        } catch RvrbError.unauthorized {
            phase = .needsLogin
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func close() {
        context?.completeRequest(returningItems: nil)
    }

    /// The shared URLs and text, one per line.
    private func sharedText() async -> String {
        var parts: [String] = []

        for item in context?.inputItems.compactMap({ $0 as? NSExtensionItem }) ?? [] {
            if let text = item.attributedContentText?.string { parts.append(text) }

            for provider in item.attachments ?? [] {
                for type in [UTType.url, .plainText, .text] where provider.hasItemConformingToTypeIdentifier(type.identifier) {
                    if let text = await Self.text(from: provider, type: type) {
                        parts.append(text)
                        break
                    }
                }
            }
        }

        return parts.joined(separator: "\n")
    }

    private static func text(from provider: NSItemProvider, type: UTType) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, _ in
                let text: String? = switch item {
                case let url as URL: url.absoluteString
                case let string as String: string
                case let attributed as NSAttributedString: attributed.string
                case let data as Data: String(data: data, encoding: .utf8)
                default: nil
                }
                continuation.resume(returning: text)
            }
        }
    }
}

struct ShareView: View {
    let model: ShareModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Add to Rvrb")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.close() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .needsLogin:
            ContentUnavailableView("Log In to Rvrb First", systemImage: "person.crop.circle.badge.exclamationmark",
                                   description: Text("Open the Rvrb app and log in, then share again."))

        case .nothing(let message):
            ContentUnavailableView("Nothing to Add", systemImage: "music.note.list", description: Text(message))

        case .ready:
            List {
                Section {
                    ForEach(model.items, id: \.self) { item in
                        ItemRow(item: item, preview: model.previews[item])
                    }
                } footer: {
                    if !model.skipped.isEmpty {
                        Text("\(model.skipped.joined(separator: " and ").capitalized) were skipped: only tracks and playlists go in the queue.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    Button {
                        Task { await model.add(playNext: false) }
                    } label: {
                        Label("Add to Queue", systemImage: "text.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        Task { await model.add(playNext: true) }
                    } label: {
                        Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }

        case .adding:
            ProgressView("Adding…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .done(let message):
            ContentUnavailableView(message, systemImage: "checkmark.circle.fill")
                .symbolRenderingMode(.multicolor)

        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't Add", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await model.add(playNext: false) } }
            }
        }
    }
}

private struct ItemRow: View {
    let item: SpotifyItem
    let preview: SpotifyPreview?

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: preview?.thumbnail) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                ZStack {
                    Rectangle().fill(.quaternary)
                    Image(systemName: isPlaylist ? "music.note.list" : "music.note")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(preview?.title ?? (isPlaylist ? "Playlist" : "Track"))
                    .lineLimit(2)
                if isPlaylist {
                    Text("Playlist: all its tracks")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var isPlaylist: Bool {
        if case .playlist = item { true } else { false }
    }
}
