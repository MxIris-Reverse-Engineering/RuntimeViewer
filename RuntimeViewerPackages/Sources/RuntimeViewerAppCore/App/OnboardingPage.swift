#if os(macOS)

import Foundation

/// One onboarding page — the welcome page or a What's New page — as values: what OnBoardingKit's
/// template shows. RuntimeViewerAppUI draws it (`makeTemplateContainerViewController(parentWindowSize:onContinue:)`)
/// in the App Store's style: the centered layout, the rows' symbols in the accent color.
public struct OnboardingPage: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Shown once, to someone who has never used the app.
        case welcome
        /// Shown once after updating to this feature release.
        case whatsNew(FeatureRelease)
    }

    /// What sits above the title.
    public enum Image: Equatable, Sendable {
        /// The app's icon, as the App Store's welcome page shows its own.
        case appIcon
        case symbol(SystemSymbol)
    }

    /// One row of the page's list.
    public struct Feature: Equatable, Sendable {
        public var title: String
        public var description: String
        public var symbol: SystemSymbol

        public init(_ title: String, description: String, symbol: SystemSymbol) {
            self.title = title
            self.description = description
            self.symbol = symbol
        }
    }

    public var kind: Kind
    public var title: String
    public var bodyText: String?
    /// The image above the title, or `nil` for none, as the App Store's What's New pages have.
    public var image: Image?
    public var features: [Feature]

    public init(kind: Kind, title: String, bodyText: String? = nil, image: Image? = nil, features: [Feature]) {
        self.kind = kind
        self.title = title
        self.bodyText = bodyText
        self.image = image
        self.features = features
    }
}

#endif
