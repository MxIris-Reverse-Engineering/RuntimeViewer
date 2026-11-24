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

    /// The size of the page: the size OnBoardingKit gives the sheets it shows itself.
    ///
    /// The framework's container sets no size of its own — its view starts at zero and its template builds
    /// its subviews only when it first draws — so a window or sheet made from it as it is would be 0 × 0
    /// and never draw. The framework's own privacy window takes its size from
    /// `+[OBStyle sheetSizeForParentWindowSize:]`, which no app can call (the SDK's stub does not export
    /// `OBStyle`); this repeats it, as on macOS 15.5 and 27.2: 482 points wide, and 88 % as tall as the
    /// window the sheet hangs off but at least 546 and at most 600 points, or 546 with no such window.
    ///
    /// - Parameter parentWindowSize: The frame size of the window the page is a sheet of, or `nil` for a
    ///   page in a window of its own.
    public static func templateContainerSize(forParentWindowSize parentWindowSize: NSSize?) -> NSSize {
        let width: CGFloat = 482
        let shortestHeight: CGFloat = 546
        let tallestHeight: CGFloat = 600
        let parentHeightFraction: CGFloat = 0.88
        guard let parentWindowSize, parentWindowSize != .zero else {
            return NSSize(width: width, height: shortestHeight)
        }
        let height = min(max(parentWindowSize.height * parentHeightFraction, shortestHeight), tallestHeight)
        return NSSize(width: width, height: height)
    }

    /// The page as OnBoardingKit's template — its symbol, title, body text and a bullet list of its
    /// features — in the framework's container, with one Continue button that answers Return.
    ///
    /// The container's view has the page's size (``templateContainerSize(forParentWindowSize:)``) as its
    /// frame and as constraints, so a window made from it (`NSWindow(contentViewController:)`) or a sheet
    /// it is presented as opens at that size.
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
        let container = OBTemplateContainerViewController(
            templateView: templateView,
            primaryButton: .init(Self.continueButtonTitle) { controller in
                Self.takeOffScreen(controller)
                onContinue()
            }
        )
        let size = Self.templateContainerSize(forParentWindowSize: parentWindowSize)
        let containerView = container.view
        containerView.setFrameSize(size)
        NSLayoutConstraint.activate([
            containerView.widthAnchor.constraint(equalToConstant: size.width),
            containerView.heightAnchor.constraint(equalToConstant: size.height),
        ])
        container.preferredContentSize = size
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
