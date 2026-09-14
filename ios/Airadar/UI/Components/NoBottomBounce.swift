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

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard observation == nil, window != nil else { return }
            var v: UIView? = superview
            while let s = v, !(s is UIScrollView) { v = s.superview }
            guard let scroll = v as? UIScrollView else { return }
            observation = scroll.observe(\.contentOffset, options: [.new]) { scroll, _ in
                let inset = scroll.adjustedContentInset
                let top = -inset.top
                let end = max(top, scroll.contentSize.height + inset.bottom - scroll.bounds.height)
                if scroll.contentOffset.y > end {
                    scroll.contentOffset.y = end
                }
            }
        }
    }
}
