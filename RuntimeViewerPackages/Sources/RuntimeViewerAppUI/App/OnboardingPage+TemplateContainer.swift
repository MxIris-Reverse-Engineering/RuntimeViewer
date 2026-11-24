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
    /// The container asks for the size OnBoardingKit gives its own sheets
    /// (`OBTemplateContainerViewController.sheetSize(forParentWindowSize:)`: 482 points wide, 88 % as tall
    /// as the parent window but 546 to 600 points, 546 with none) as its `preferredContentSize`, so a
    /// window made from it (`NSWindow(contentViewController:)`) or a sheet it is presented as opens at
    /// that size, and the template fills it.
    ///
    /// Continue takes the container off screen however it was shown — dismissed when a view controller
    /// presented it, its sheet ended when it is the content of a sheet window, its window closed otherwise —
    /// and then calls `onContinue`.
    ///
    /// - Parameter parentWindowSize: The frame size of the window the page is going to be a sheet of, or
    ///   `nil` for a page in a window of its own.
    /// - Returns: `nil` when the system has no OnBoardingKit (``isPresentable``).
    @MainActor
    public func makeTemplateContainerViewController(
        parentWindowSize: NSSize?,
        onContinue: @escaping @MainActor () -> Void
    ) -> NSViewController? {
        guard Self.isPresentable else { return nil }
        let templateView = OBTemplateView(title: title, bodyText: bodyText, systemImage: symbol.rawValue) {
            for feature in features {
                OBTemplatePartBulletList.Item(feature.title, description: feature.description, systemImage: feature.symbol.rawValue)
            }
        }
        // The initializers give the template the standard type, whose 175-point side margins are meant for a
        // whole window: in a 482-point sheet they leave the text a column about 130 points wide. The centered
        // type has 68-point margins, and keeps its bullet list's rows 344 points wide, the width that leaves.
        // The template reads its type when it first draws.
        templateView.templateType = .centered
        templateView.bulletList?.templateType = .centered
        let container = OBTemplateContainerViewController(
            templateView: templateView,
            primaryButton: .init(Self.continueButtonTitle) { controller in
                Self.takeOffScreen(controller)
                onContinue()
            }
        )
        container.preferredContentSize = OBTemplateContainerViewController.sheetSize(forParentWindowSize: parentWindowSize)
        return container
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
