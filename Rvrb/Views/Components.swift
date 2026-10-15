import SwiftUI

/// Album artwork with a placeholder.
struct Artwork: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        RemoteImage(url: url, maxPixelSize: size * 3) { _ in
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8))
    }
}

struct TrackRow: View {
    let track: Track
    let number: Int?
    /// Never played on RVRB: playing it earns a first play.
    var isFirstPlay = false

    var body: some View {
        HStack(spacing: 10) {
            if let number {
                Text("\(number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 22, alignment: .trailing)
            }
            Artwork(url: track.artworkURL(minWidth: 64), size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if isFirstPlay {
                        Label("First", systemImage: "sparkles")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tint)
                            .labelStyle(.titleAndIcon)
                            .help("Never played on RVRB: playing it is a first play")
                    }
                    Text(track.artists)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(track.duration.minutesAndSeconds)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

/// A user's picture, or their initial on a colour of their own.
struct Avatar: View {
    static let size: CGFloat = 30

    let name: String
    let url: URL?
    let seed: String
    var activity: UserActivity = .listening
    /// Starred (bookmarked) the playing track: a star at the top, besides any other badge.
    var starred = false
    var size: CGFloat = Avatar.size

    var body: some View {
        picture
            .overlay(alignment: .bottomTrailing) { badge }
            .overlay(alignment: .topTrailing) { starBadge }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var starBadge: some View {
        if starred {
            Image(systemName: "star.fill")
                .font(.system(size: size * 0.26, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size * 0.44, height: size * 0.44)
                .background(.yellow, in: Circle())
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                .offset(x: size * 0.08, y: -size * 0.08)
        }
    }

    /// The state badge, for users without their own DJ/dope/nope pictures (and to make it obvious for those with).
    @ViewBuilder
    private var badge: some View {
        if let (symbol, color) = badgeStyle {
            Image(systemName: symbol)
                .font(.system(size: size * 0.3, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size * 0.48, height: size * 0.48)
                .background(color, in: Circle())
                .overlay(Circle().stroke(.background, lineWidth: 1.5))
                .offset(x: size * 0.08, y: size * 0.08)
        }
    }

    private var badgeStyle: (String, Color)? {
        switch activity {
        case .listening: nil
        case .djing: ("music.mic", .accentColor)
        case .doped: ("hand.thumbsup.fill", .green)
        case .noped: ("hand.thumbsdown.fill", .red)
        }
    }

    private var picture: some View {
        Group {
            if let url {
                RemoteImage(url: url, maxPixelSize: size * 3) { _ in
                    initial
                }
            } else {
                initial
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var initial: some View {
        ZStack {
            Circle().fill(Self.color(for: seed).gradient)
            Text(name.first.map { String($0).uppercased() } ?? "?")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(.white)
        }
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green, .mint, .cyan, .brown]

    /// A colour per user that stays the same between launches (Swift's hashValue doesn't).
    static func color(for seed: String) -> Color {
        let hash = seed.unicodeScalars.reduce(UInt32(5381)) { ($0 &<< 5) &+ $0 &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }
}

/// Marks a bot's name, like chat apps do.
struct BotTag: View {
    var body: some View {
        Text("BOT")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(.tint, in: RoundedRectangle(cornerRadius: 3))
            .accessibilityLabel("Bot")
    }
}
