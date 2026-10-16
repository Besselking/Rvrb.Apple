import Observation
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// An easter egg (Mac): grab a spinning chat image (/spin) and hold it still, and the chat spins around it
/// instead, at the image's one turn a second. Letting go springs it back upright.
///
/// What spins is a snapshot of the chat laid over it, with the held image cut out of it and kept still on top:
/// turning the live interface was slow and moved the chat under the pointer. The sidebars stay as they are.
@Observable
final class SpinGrab {
    /// When the image was grabbed; nil while nothing is held.
    private(set) var grabbedAt: Date?
    /// The held image's view, for its grabbing cursor.
    private(set) var holder: UUID?
    /// The window as it was when grabbed, and its points-to-pixels scale.
    private(set) var snapshot: CGImage?
    private(set) var scale: CGFloat = 2
    /// The chat's frame in the window (set by the chat), the area that spins.
    var area: CGRect = .zero
    /// The held image's centre in the chat, and its size.
    private(set) var center: CGPoint = .zero
    private(set) var side: CGFloat = 0
    /// The snapshot's angle once let go, animated to a whole turn.
    private(set) var settledAngle: Double = 0

    var isHeld: Bool { grabbedAt != nil }

    /// Where the snapshot turns: the held image's centre.
    var anchor: UnitPoint {
        guard let snapshot, snapshot.width > 0, snapshot.height > 0 else { return .center }
        return UnitPoint(x: center.x * scale / CGFloat(snapshot.width), y: center.y * scale / CGFloat(snapshot.height))
    }

    /// The snapshot's angle: turning while held, settling afterwards.
    func angle(at date: Date) -> Double {
        grabbedAt.map { date.timeIntervalSince($0) * 360 } ?? settledAngle
    }

    /// `center` is in the window.
    func grab(_ holder: UUID, center: CGPoint, side: CGFloat) {
        guard grabbedAt == nil, area.width > 0, area.height > 0,
              let (window, scale) = Self.windowSnapshot(),
              let image = window.cropping(to: CGRect(x: area.minX * scale, y: area.minY * scale,
                                                     width: area.width * scale, height: area.height * scale))
        else { return }
        self.holder = holder
        self.center = CGPoint(x: center.x - area.minX, y: center.y - area.minY)
        self.side = side
        snapshot = image
        self.scale = scale
        settledAngle = 0
        grabbedAt = .now
    }

    func release() {
        guard let grabbedAt else { return }
        let angle = Date.now.timeIntervalSince(grabbedAt) * 360
        settledAngle = angle
        self.grabbedAt = nil
        holder = nil

        // Back upright the short way (the nearest whole turn), then show the real window again.
        withAnimation(.spring(duration: 0.9, bounce: 0.25)) {
            settledAngle = (angle / 360).rounded() * 360
        } completion: {
            if self.grabbedAt == nil { self.snapshot = nil }
        }
    }

    /// The key window's content, as drawn now.
    private static func windowSnapshot() -> (CGImage, CGFloat)? {
        #if os(macOS)
        guard let view = NSApp.keyWindow?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let image = rep.cgImage, view.bounds.width > 0 else { return nil }
        return (image, CGFloat(rep.pixelsWide) / view.bounds.width)
        #else
        return nil
        #endif
    }
}

/// Lays the spinning snapshot over the chat while an image is held (and while it settles).
struct SpinGrabArea: ViewModifier {
    let grab: SpinGrab

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { grab.area = $0 }
            .overlay {
                if let snapshot = grab.snapshot {
                    TimelineView(.animation(minimumInterval: nil, paused: !grab.isHeld)) { context in
                        let picture = Image(decorative: snapshot, scale: grab.scale).resizable()
                        ZStack {
                            background
                            picture
                                .rotationEffect(.degrees(grab.angle(at: context.date)), anchor: grab.anchor)
                            // The held image, cut out of the snapshot and kept still.
                            picture
                                .mask {
                                    Circle()
                                        .frame(width: grab.side, height: grab.side)
                                        .position(grab.center)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                                }
                        }
                    }
                    .clipped()
                    .allowsHitTesting(false)
                }
            }
    }

    private var background: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}
