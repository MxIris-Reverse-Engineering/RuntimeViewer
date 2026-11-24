#if os(macOS)

import AppKit
import OnBoardingKit
import RuntimeViewerAppCore

/// Draws an onboarding page with OnBoardingKit, the private framework behind the welcome and What's New
/// pages of Apple's own apps, through swift-onboardingkit (proposal `onboarding-pages`).
extension OnboardingPage {
    /// Whether this system has OnBoardingKit. swift-onboardingkit links the framework weakly, so on a
    /// system without it the app still launches and the framework's classes look up as `nil`; creating one
    /// there would crash.
    public static var isPresentable: Bool {
        NSClassFromString("OBTemplateContainerViewController") != nil
            && NSClassFromString("OBTemplateView") != nil
            && NSClassFromString("OBTemplatePartBulletList") != nil
    }

    /// The title of the page's one button.
    static let continueButtonTitle = "Continue"

    /// The page as OnBoardingKit's template — its symbol, title, body text and a bullet list of its
    /// features — in the framework's container, with one Continue button that answers Return.
    ///
    /// Continue takes the container off screen however it was shown — dismissed when a view controller
    /// presented it, its sheet ended when it is the content of a sheet window, its window closed otherwise —
    /// and then calls `onContinue`.
    ///
    /// - Returns: `nil` when the system has no OnBoardingKit (``isPresentable``).
    @MainActor
    public func makeTemplateContainerViewController(onContinue: @escaping @MainActor () -> Void) -> NSViewController? {
        guard Self.isPresentable else { return nil }
        let templateView = OBTemplateView(title: title, bodyText: bodyText, systemImage: symbol.rawValue) {
            for feature in features {
                OBTemplatePartBulletList.Item(feature.title, description: feature.description, systemImage: feature.symbol.rawValue)
            }
        }
        return OBTemplateContainerViewController(
            templateView: templateView,
            primaryButton: .init(Self.continueButtonTitle) { controller in
                Self.takeOffScreen(controller)
                onContinue()
            }
        )
    }

    @MainActor
    private static func takeOffScreen(_ controller: NSViewController) {
        if controller.presentingViewController != nil {
            controller.dismiss(nil)
        } else if let window = controller.viewIfLoaded?.window {
            if let sheetParent = window.sheetParent {
                sheetParent.endSheet(window)
            } else {
                window.close()
            }
        }
    }
}

#endif
