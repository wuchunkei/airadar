import SwiftUI
import UIKit

/// Keeps the trip list fenced at the present heading. The past rows are always in
/// the list, above; closed, the fence's top edge is the heading, so they are out
/// of reach and a pull past it rubber-bands and springs back (refreshing, or —
/// pulled far enough — opening the fence). Open, the top edge is the real top and
/// the bottom edge is the heading, so scrolling back down springs to the present
/// and, once at rest there after a visit, the fence closes with nothing moving.
///
/// Sits as the background of the heading row, so it finds the List's own scroll
/// view above it and its own position gives the heading's offset.
struct PresentFence: UIViewRepresentable {
    var open: Bool
    /// Height of the empty row at the list's tail, discounted when measuring the content's end.
    var tail: CGFloat
    var onPull: (CGFloat) -> Void
    var onRelease: (CGFloat) -> Void
    var onSettled: () -> Void

    func makeUIView(context: Context) -> Fence { Fence() }
    func updateUIView(_ v: Fence, context: Context) {
        v.tail = tail; v.onPull = onPull; v.onRelease = onRelease; v.onSettled = onSettled
        if v.open != open { v.open = open; v.enforce() }
    }

    @MainActor
    final class Fence: UIView {
        var open = false { didSet { if open != oldValue { visited = false } } }
        var tail: CGFloat = 0
        var onPull: (CGFloat) -> Void = { _ in }
        var onRelease: (CGFloat) -> Void = { _ in }
        var onSettled: () -> Void = {}

        private weak var scroll: UIScrollView?
        private var offsetObs: NSKeyValueObservation?
        private var sizeObs: NSKeyValueObservation?
        private var busy = false
        private var springing = false
        private var visited = false
        private var heading: CGFloat?  // the offset at which the heading sits at the top; cached while off-screen
        private var settleTask: Task<Void, Never>?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard scroll == nil, window != nil else { return }
            var v: UIView? = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let s = v as? UIScrollView else { return }
            scroll = s
            s.panGestureRecognizer.addTarget(self, action: #selector(pan(_:)))
            offsetObs = s.observe(\.contentOffset, options: [.new]) { [weak self] s, _ in
                MainActor.assumeIsolated { self?.offsetChanged(s) }
            }
            sizeObs = s.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.enforce() }
            }
            enforce()
        }

        // MARK: edges

        private struct Edges { let top: CGFloat; let heading: CGFloat; let lo: CGFloat; let hi: CGFloat }

        private func edges(_ s: UIScrollView) -> Edges? {
            let inset = s.adjustedContentInset
            let top = -inset.top
            if window != nil { heading = convert(CGPoint.zero, to: s).y - inset.top }
            guard let h = heading else { return nil }
            let present = max(top, h)
            let naturalEnd = max(top, s.contentSize.height + inset.bottom - s.bounds.height - tail)
            return Edges(top: top, heading: present, lo: open ? top : present, hi: max(present, naturalEnd))
        }

        /// Without ceremony: used when the content or the state changes under a resting list.
        func enforce() {
            guard let s = scroll, !s.isDragging, !springing, let e = edges(s) else { return }
            let y = s.contentOffset.y
            if y < e.lo { set(s, e.lo) } else if y > e.hi { set(s, e.hi) }
        }

        private func set(_ s: UIScrollView, _ y: CGFloat) {
            busy = true
            s.contentOffset.y = y
            busy = false
        }

        // MARK: scrolling

        private func offsetChanged(_ s: UIScrollView) {
            guard !busy, !springing, let e = edges(s) else { return }
            let y = s.contentOffset.y
            if open, y < e.heading - 60 { visited = true }
            if s.isDragging {
                // Beyond an edge the finger only gets half of what it asks for.
                if y < e.lo {
                    let over = (e.lo - y) * 0.5
                    set(s, e.lo - over); onPull(over)
                } else if y > e.hi {
                    set(s, e.hi + (y - e.hi) * 0.5); onPull(0)
                } else {
                    onPull(0)
                }
            } else if s.isDecelerating, y < e.lo || y > e.hi {
                // Momentum ran into an edge: a little give, then a spring back.
                let target = y < e.lo ? e.lo : e.hi
                let give = min(28, abs(y - target))
                set(s, target + (y < e.lo ? -give : give))
                spring(s, to: target)
            }
        }

        @objc private func pan(_ g: UIPanGestureRecognizer) {
            guard g.state == .ended || g.state == .cancelled, let s = scroll, let e = edges(s) else { return }
            let y = s.contentOffset.y
            if y < e.lo {
                onRelease(e.lo - y)
                set(s, y)  // cancels the deceleration UIKit just started
                spring(s, to: e.lo)
            } else if y > e.hi {
                set(s, y)
                spring(s, to: e.hi)
            } else {
                watchForRest(s)
            }
            onPull(0)
        }

        private func spring(_ s: UIScrollView, to target: CGFloat) {
            springing = true
            UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.78, initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction, .beginFromCurrentState]) {
                s.contentOffset.y = target
            } completion: { [weak self] _ in
                self?.springing = false
                self?.settled(s)
            }
        }

        /// Deceleration inside the fence ends on its own; look in on it until it has.
        private func watchForRest(_ s: UIScrollView) {
            settleTask?.cancel()
            settleTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(100))
                    guard let self, let s = self.scroll else { return }
                    if !s.isDecelerating && !s.isDragging { self.settled(s); return }
                }
            }
        }

        /// At rest. Open, after a visit to the past, back at (or below) the heading: close.
        private func settled(_ s: UIScrollView) {
            guard open, visited, let e = edges(s), s.contentOffset.y >= e.heading - 2 else { return }
            onSettled()
        }
    }
}
