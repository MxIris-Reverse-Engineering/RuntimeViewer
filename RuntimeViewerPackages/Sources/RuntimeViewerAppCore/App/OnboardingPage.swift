#if os(macOS)

import Foundation

/// One onboarding page — the welcome page or a What's New page — as values: what OnBoardingKit's
/// template shows. RuntimeViewerAppUI draws it (`makeTemplateContainerViewController(onContinue:)`).
public struct OnboardingPage: Equatable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// Shown once, to someone who has never used the app.
        case welcome
        /// Shown once after updating to this feature release.
        case whatsNew(FeatureRelease)
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
    /// The symbol above the title.
    public var symbol: SystemSymbol
    public var features: [Feature]

    public init(kind: Kind, title: String, bodyText: String? = nil, symbol: SystemSymbol, features: [Feature]) {
        self.kind = kind
        self.title = title
        self.bodyText = bodyText
        self.symbol = symbol
        self.features = features
    }
}

#endif
