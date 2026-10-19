import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RvrbWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ChannelLiveActivity()
    }
}

private let accent = Color(red: 0.553, green: 0.361, blue: 0.902)

/// The joined channel with Dope, Nope and Favorite buttons that vote on whatever is playing. No track details or
/// counts: they'd be stale while the app sleeps.
struct ChannelLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RvrbActivityAttributes.self) { context in
            VStack(spacing: 12) {
                ChannelHeader(context: context)
                VoteButtons(context: context)
            }
            .padding()
            .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Logo(size: 40)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    ChannelText(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VoteButtons(context: context, compact: true)
                        .padding(.horizontal, 4)
                }
            } compactLeading: {
                Logo(size: 22)
            } compactTrailing: {
                Image(systemName: context.isStale || context.state.confirmation == nil ? "waveform" : "checkmark")
                    .foregroundStyle(accent)
            } minimal: {
                Logo(size: 22)
            }
            .keylineTint(accent)
        }
    }
}

private struct ChannelHeader: View {
    let context: ActivityViewContext<RvrbActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            Logo(size: 44)
            ChannelText(context: context)
            Spacer(minLength: 0)
        }
    }
}

private struct ChannelText: View {
    let context: ActivityViewContext<RvrbActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(context.attributes.channelTitle)
                .font(.headline)
                .lineLimit(1)
            Group {
                if let confirmation = context.state.confirmation, !context.isStale {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .foregroundStyle(accent)
                } else {
                    Text("Vote on what's playing")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
            .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Each button adds that vote to the playing track (switching between dope and nope); it never takes one back.
private struct VoteButtons: View {
    let context: ActivityViewContext<RvrbActivityAttributes>
    var compact = false

    var body: some View {
        HStack(spacing: 8) {
            button("dope", title: "Dope", icon: "hand.thumbsup.fill", tint: .green)
            button("nope", title: "Nope", icon: "hand.thumbsdown.fill", tint: .red)
            button("star", title: "Favorite", icon: "bookmark.fill", tint: .yellow)
        }
    }

    private func button(_ vote: String, title: String, icon: String, tint: Color) -> some View {
        Button(intent: VoteIntent(vote: vote, channelId: context.attributes.channelId,
                                  channelTitle: context.attributes.channelTitle)) {
            Label(title, systemImage: icon)
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(compact ? .small : .regular)
        .tint(tint)
    }
}

/// The app's mark: a note with echoes on the purple.
private struct Logo: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.25)
                .fill(LinearGradient(colors: [Color(red: 0.655, green: 0.482, blue: 0.961), Color(red: 0.357, green: 0.247, blue: 0.82)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}
