import SwiftUI
import UIKit

/// Stops the enclosing scroll view dead at its end instead of rubber-banding past
/// it; the top keeps its pull (refresh, and the past unfolding). Placed as a
/// background, it finds the List's UIScrollView above it in the view tree.
struct NoBottomBounce: UIViewRepresentable {
    func makeUIView(context: Context) -> Finder { Finder() }
    func updateUIView(_ view: Finder, context: Context) {}

    final class Finder: UIView {
        private var observation: NSKeyValueObservation?
        private var clamping = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observation == nil, window != nil else { return }
            var v: UIView? = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let scroll = v as? UIScrollView else { return }
            // KVO fires on the thread that scrolls, which for UIKit is always main.
            observation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    guard let self, !self.clamping else { return }
                    // Only while the finger (or its momentum) drives the scroll; a List
                    // animating rows in and out must be left to place itself.
                    guard scroll.isDragging || scroll.isDecelerating else { return }
                    let inset = scroll.adjustedContentInset
                    let top = -inset.top
                    // On the pixel grid: UIKit snaps what it stores, and writing a value it
                    // then rounds back above the end would fire this observer without end.
                    let scale = scroll.traitCollection.displayScale
                    let end = (max(top, scroll.contentSize.height + inset.bottom - scroll.bounds.height) * scale).rounded(.up) / scale
                    if scroll.contentOffset.y > end + 0.5 {
                        self.clamping = true
                        scroll.contentOffset.y = end
                        self.clamping = false
                    }
                }
            }
        }
    }
}
