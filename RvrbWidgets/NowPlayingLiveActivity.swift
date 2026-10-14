import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

@main
struct RvrbWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NowPlayingLiveActivity()
    }
}

private let accent = Color(red: 0.553, green: 0.361, blue: 0.902)

struct NowPlayingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RvrbActivityAttributes.self) { context in
            LockScreenView(context: context)
                .padding()
                .activitySystemActionForegroundColor(accent)
        } dynamicIsland: { context in
            let state = context.state

            return DynamicIsland {
                // The expanded island is only so tall: two lines of text and small buttons.
                DynamicIslandExpandedRegion(.leading) {
                    ArtworkView(data: state.artwork, size: 46)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Label(context.attributes.channelTitle, systemImage: "waveform")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(accent)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    TrackText(context: context, compact: true)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        TrackProgress(state: state)
                        VoteButtons(context: context, compact: true)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                ArtworkView(data: state.artwork, size: 24)
            } compactTrailing: {
                ProgressView(timerInterval: state.start...max(state.end, state.start), countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.circular)
                .tint(accent)
                .frame(width: 22, height: 22)
            } minimal: {
                ArtworkView(data: state.artwork, size: 24)
            }
            .keylineTint(accent)
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<RvrbActivityAttributes>

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                ArtworkView(data: context.state.artwork, size: 60)
                TrackText(context: context)
                Spacer(minLength: 0)
            }
            TrackProgress(state: context.state)
            VoteButtons(context: context)
        }
    }
}

private struct TrackText: View {
    let context: ActivityViewContext<RvrbActivityAttributes>
    /// Track and artist only (the Dynamic Island); stale shows in place of the artist.
    var compact = false

    var body: some View {
        let state = context.state

        VStack(alignment: .leading, spacing: 2) {
            Text(state.track)
                .font(.headline)
                .lineLimit(1)
            Text(compact && context.isStale ? "Open Rvrb to catch up" : state.artists)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !compact {
                detail
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var detail: some View {
        let state = context.state

        return Group {
            if context.isStale {
                Text("Open Rvrb to catch up")
            } else if let dj = state.dj {
                Text("\(dj) · \(context.attributes.channelTitle)")
            } else {
                Text(context.attributes.channelTitle)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

private struct TrackProgress: View {
    let state: RvrbActivityAttributes.ContentState

    var body: some View {
        let range = state.start...max(state.end, state.start)

        HStack(spacing: 8) {
            Text(timerInterval: range, countsDown: false)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .leading)
            ProgressView(timerInterval: range, countsDown: false) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .tint(accent)
            Text(timerInterval: range, countsDown: true)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
        }
    }
}

private struct VoteButtons: View {
    let context: ActivityViewContext<RvrbActivityAttributes>
    /// Small buttons for the Dynamic Island.
    var compact = false

    var body: some View {
        let state = context.state

        HStack(spacing: 8) {
            button("dope", icon: "hand.thumbsup", count: state.dope, isOn: state.myDope, tint: .green)
            button("nope", icon: "hand.thumbsdown", count: state.nope, isOn: state.myNope, tint: .red)
            button("star", icon: "star", count: state.star, isOn: state.myStar, tint: .yellow)
        }
    }

    @ViewBuilder
    private func button(_ vote: String, icon: String, count: Int, isOn: Bool, tint: Color) -> some View {
        let label = Label {
            Text("\(count)").monospacedDigit()
        } icon: {
            Image(systemName: isOn ? icon + ".fill" : icon)
                .foregroundStyle(isOn ? tint : .secondary)
        }
        .font(compact ? .caption : .subheadline)
        .frame(maxWidth: .infinity)

        if context.state.isMyTrack {
            // Voting on your own track fails: show the counts only.
            label.padding(.vertical, compact ? 2 : 6)
        } else {
            Button(intent: VoteIntent(vote: vote, channelId: context.attributes.channelId,
                                      channelTitle: context.attributes.channelTitle)) {
                label
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(compact ? .small : .regular)
            .tint(isOn ? tint : .gray)
        }
    }
}

private struct ArtworkView: View {
    let data: Data?
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    accent.opacity(0.3)
                    Image(systemName: "music.note").foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 6))
    }
}
