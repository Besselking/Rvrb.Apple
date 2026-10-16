import Observation
import SwiftUI

/// An easter egg (Mac): grab a spinning chat image (/spin) and hold it still, and the rest of the window spins
/// around it instead, at the image's one turn a second. Letting go springs the window back upright.
@Observable
final class SpinGrab {
    nonisolated static let coordinateSpace = "rvrb.window"

    /// When the image was grabbed; nil while nothing is held.
    private(set) var grabbedAt: Date?
    /// The held image's view, so only that one stands still.
    private(set) var holder: UUID?
    /// Where the window turns: the held image's centre.
    private(set) var anchor: UnitPoint = .center
    /// The held image's angle when it was grabbed, kept on screen while the window turns.
    private(set) var frozenAngle: Double = 0
    /// The window's angle once let go, animated to a whole turn.
    private(set) var settledAngle: Double = 0

    /// The window's size, for turning the image's centre into an anchor.
    var windowSize: CGSize = .zero

    var isHeld: Bool { grabbedAt != nil }

    /// The window's angle: turning while held, settling afterwards.
    func windowAngle(at date: Date) -> Double {
        grabbedAt.map { date.timeIntervalSince($0) * 360 } ?? settledAngle
    }

    func grab(_ holder: UUID, center: CGPoint, imageAngle: Double) {
        guard grabbedAt == nil, windowSize.width > 0, windowSize.height > 0 else { return }
        self.holder = holder
        anchor = UnitPoint(x: center.x / windowSize.width, y: center.y / windowSize.height)
        frozenAngle = imageAngle
        settledAngle = 0
        grabbedAt = .now
    }

    func release() {
        guard let grabbedAt else { return }
        let angle = Date.now.timeIntervalSince(grabbedAt) * 360
        settledAngle = angle
        self.grabbedAt = nil
        holder = nil
        // Back upright the short way: the nearest whole turn.
        withAnimation(.spring(duration: 0.9, bounce: 0.25)) {
            settledAngle = (angle / 360).rounded() * 360
        }
    }
}

/// Turns the window's content around the held image. Paused (and upright) when nothing is held.
struct SpinGrabWindow: ViewModifier {
    let grab: SpinGrab

    func body(content: Content) -> some View {
        TimelineView(.animation(minimumInterval: nil, paused: !grab.isHeld)) { context in
            content
                .rotationEffect(.degrees(grab.windowAngle(at: context.date)), anchor: grab.anchor)
        }
        .coordinateSpace(.named(SpinGrab.coordinateSpace))
        .onGeometryChange(for: CGSize.self) { $0.size } action: { grab.windowSize = $0 }
    }
}
