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

    /// The side of the app's icon above the welcome page's title, the size the App Store gives its own.
    static let appIconSide: CGFloat = 128

    /// The page as swift-onboardingkit's page value, in the App Store's style: the centered layout (68-point
    /// side margins, the image centered above the text) and the rows' symbols in the accent color. Its size is
    /// the one OnBoardingKit gives its own sheets (`OBTemplateContainerViewController.sheetSize(forParentWindowSize:)`:
    /// 482 points wide, 88 % as tall as the parent window but 546 to 600 points, 546 with none).
    ///
    /// - Parameter parentWindowSize: The frame size of the window the page is going to be a sheet of, or
    ///   `nil` for a page in a window of its own.
    @MainActor
    func templatePage(parentWindowSize: NSSize?) -> OBTemplatePage {
        OBTemplatePage(
            title: title,
            bodyText: bodyText,
            image: image.map(Self.templateImage(for:)),
            features: features.map { feature in
                OBTemplatePartBulletList.Item(feature.title, description: feature.description, systemImage: feature.symbol.rawValue)
            },
            featureTintColor: .controlAccentColor,
            layout: .centered,
            size: OBTemplateContainerViewController.sheetSize(forParentWindowSize: parentWindowSize)
        )
    }

    @MainActor
    private static func templateImage(for image: Image) -> OBTemplatePage.Image {
        switch image {
        case .appIcon:
            // A copy: the named application icon is the one the rest of the app shows, and the page sizes it.
            let icon = (NSImage(named: NSImage.applicationIconName)?.copy() as? NSImage) ?? NSImage()
            icon.size = NSSize(width: appIconSide, height: appIconSide)
            return .image(icon)
        case .symbol(let symbol):
            return .systemImage(symbol.rawValue)
        }
    }

    /// The page in OnBoardingKit's container, assembled by swift-onboardingkit from ``templatePage(parentWindowSize:)``,
    /// with one Continue button that answers Return. A window made from it (`NSWindow(contentViewController:)`) or a
    /// sheet it is presented as opens at the page's size.
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
        return OBTemplateContainerViewController(
            page: templatePage(parentWindowSize: parentWindowSize),
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
