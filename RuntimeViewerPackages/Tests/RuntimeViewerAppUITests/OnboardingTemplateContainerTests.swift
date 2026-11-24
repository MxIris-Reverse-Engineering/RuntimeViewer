#if os(macOS)

import AppKit
import OnBoardingKit
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI

/// An onboarding page drawn as OnBoardingKit's template in its container (proposal `onboarding-pages`).
/// No window is put on screen.
@MainActor
@Suite("Onboarding template container")
struct OnboardingTemplateContainerTests {
    private static let page = OnboardingPage(
        kind: .whatsNew(FeatureRelease(major: 3, minor: 0)),
        title: "What’s New in RuntimeViewer 3.0",
        bodyText: "Body text",
        symbol: .sparkles,
        features: [
            .init("Find Navigator", description: "Search every indexed interface.", symbol: .magnifyingglass),
            .init("Editor Panes", description: "Split the content area.", symbol: .rectangleSplit2x1),
        ]
    )

    private static func makeContainer(onContinue: @escaping @MainActor () -> Void = {}) throws -> OBTemplateContainerViewController {
        let viewController = try #require(page.makeTemplateContainerViewController(onContinue: onContinue))
        return try #require(viewController as? OBTemplateContainerViewController)
    }

    @Test("this system has OnBoardingKit")
    func systemHasOnBoardingKit() {
        #expect(OnboardingPage.isPresentable)
    }

    @Test("the template shows the page's title and body text")
    func templateContainerShowsPageTitle() throws {
        let templateView = try #require(try Self.makeContainer().templateView)

        #expect(templateView.title == Self.page.title)
        #expect(templateView.bodyText == Self.page.bodyText)
    }

    @Test("the bullet list has a row for each feature, in order")
    func bulletListHasARowForEachFeature() throws {
        let templateView = try #require(try Self.makeContainer().templateView)
        let stack = try #require(templateView.bulletList?.stack)

        let rows = stack.arrangedSubviews.compactMap { $0 as? OBTemplatePartBulletListItem }

        #expect(rows.count == Self.page.features.count)
    }

    @Test("the tray has only a Continue button, which answers Return")
    func templateContainerHasOnlyContinueButton() throws {
        let container = try Self.makeContainer()

        let primaryButton = try #require(container.button(for: .primary))
        #expect(primaryButton.title == "Continue")
        #expect(primaryButton.keyEquivalent == "\r")
        #expect(container.button(for: .secondary).map { $0.isHidden || $0.title.isEmpty } ?? true)
        #expect(container.button(for: .cancel).map { $0.isHidden || $0.title.isEmpty } ?? true)
    }

    @Test("Continue calls onContinue once")
    func continueButtonCallsOnContinueOnce() throws {
        var continueCount = 0
        let container = try Self.makeContainer { continueCount += 1 }

        try #require(container.button(for: .primary)).performClick(nil)

        #expect(continueCount == 1)
    }
}

#endif
