import SwiftUI

/// A sheet height that tracks the sheet's own measured content.
///
/// iOS 27 ignores SwiftUI detent changes made after a sheet is presented, so a
/// sheet that opens before its content is measured can't be moved to the right
/// height by swapping detents. Instead each sheet uses a custom detent whose
/// height is read from a stored value: the sheet opens at the last height seen
/// (right straight away from the second time on), and once the content is
/// measured `SheetDetentRefresher` asks UIKit to read it again.
protocol FittedSheetDetent: CustomPresentationDetent {
    static var fittedHeight: CGFloat { get set }
}

extension FittedSheetDetent {
    static func height(in context: Context) -> CGFloat? { min(fittedHeight, context.maxDetentValue) }
}

enum DetailSheetDetent: FittedSheetDetent {
    nonisolated(unsafe) static var fittedHeight: CGFloat = 600
}

enum MapChooserSheetDetent: FittedSheetDetent {
    nonisolated(unsafe) static var fittedHeight: CGFloat = 240
}

/// Stores a measured height for `Detent` and has the sheet this view sits in
/// re-read it, through `invalidateDetents` — the detents themselves stay
/// SwiftUI's own.
struct SheetDetentRefresher<Detent: FittedSheetDetent>: UIViewRepresentable {
    let height: CGFloat

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        guard height > 0, abs(Detent.fittedHeight - height) >= 0.5 else { return }
        Detent.fittedHeight = height
        refresh(from: view, attemptsLeft: 8)
    }

    /// Retried briefly: on the first pass the view isn't in the window yet.
    private func refresh(from view: UIView, attemptsLeft: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (attemptsLeft == 8 ? 0 : 0.1)) {
            guard let sheet = Self.sheetController(from: view) else {
                if attemptsLeft > 0 { refresh(from: view, attemptsLeft: attemptsLeft - 1) }
                return
            }
            sheet.animateChanges { sheet.invalidateDetents() }
        }
    }

    /// The sheet this view is showing in. Reads `presentationController`, never
    /// `sheetPresentationController`, which can create a sheet controller on a
    /// view controller that isn't being shown as one.
    private static func sheetController(from view: UIView) -> UISheetPresentationController? {
        guard view.window != nil else { return nil }
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        var controller = responder as? UIViewController
        while let parent = controller?.parent { controller = parent }
        guard let controller, !controller.isBeingDismissed,
              let sheet = controller.presentationController as? UISheetPresentationController,
              sheet.presentedViewController === controller else { return nil }
        return sheet
    }
}
