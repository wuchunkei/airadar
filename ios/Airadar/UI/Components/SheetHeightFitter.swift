import SwiftUI

/// Resizes the sheet this view sits in, via its UISheetPresentationController.
/// iOS 27 ignores SwiftUI detent changes made after a sheet is presented, so a
/// height only known once content is measured has to be set here directly.
struct SheetHeightFitter: UIViewRepresentable {
    let height: CGFloat
    let fits: Bool

    final class Coordinator { var applied: (CGFloat, Bool)? }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView { UIView(frame: .zero) }

    func updateUIView(_ view: UIView, context: Context) {
        guard height > 0 else { return }
        let height = height, fits = fits
        if let applied = context.coordinator.applied, abs(applied.0 - height) < 0.5, applied.1 == fits { return }
        let coordinator = context.coordinator
        // Not in the window yet on the first pass; the controller chain is there a turn later.
        DispatchQueue.main.async {
            guard let sheet = Self.sheetController(from: view) else { return }
            coordinator.applied = (height, fits)
            let fittedId = UISheetPresentationController.Detent.Identifier("airadar.fitted")
            let fitted = UISheetPresentationController.Detent.custom(identifier: fittedId) { context in
                min(height, context.maximumDetentValue)
            }
            sheet.animateChanges {
                sheet.detents = fits ? [fitted] : [fitted, .large()]
                sheet.selectedDetentIdentifier = fittedId
            }
        }
    }

    private static func sheetController(from view: UIView) -> UISheetPresentationController? {
        var responder: UIResponder? = view
        while let r = responder, !(r is UIViewController) { responder = r.next }
        var controller = responder as? UIViewController
        while let parent = controller?.parent { controller = parent }
        return controller?.sheetPresentationController
    }
}
