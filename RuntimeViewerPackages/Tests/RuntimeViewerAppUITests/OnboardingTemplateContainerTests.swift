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

    private static func makeContainer(
        parentWindowSize: NSSize? = nil,
        onContinue: @escaping @MainActor () -> Void = {}
    ) throws -> OBTemplateContainerViewController {
        let viewController = try #require(page.makeTemplateContainerViewController(parentWindowSize: parentWindowSize, onContinue: onContinue))
        return try #require(viewController as? OBTemplateContainerViewController)
    }

    private static let sheetWidth: CGFloat = 482
    private static let shortestSheetHeight: CGFloat = 546
    private static let tallestSheetHeight: CGFloat = 600

    @Test("with no parent window the page is as large as OnBoardingKit's own sheet without one")
    func sizeWithoutParentWindow() {
        let size = OnboardingPage.templateContainerSize(forParentWindowSize: nil)

        #expect(size == NSSize(width: Self.sheetWidth, height: Self.shortestSheetHeight))
    }

    @Test("on a short window the page keeps OnBoardingKit's shortest sheet height")
    func sizeOnShortParentWindow() {
        let size = OnboardingPage.templateContainerSize(forParentWindowSize: NSSize(width: 800, height: 500))

        #expect(size == NSSize(width: Self.sheetWidth, height: Self.shortestSheetHeight))
    }

    @Test("on a tall window the page stops at OnBoardingKit's tallest sheet height")
    func sizeOnTallParentWindow() {
        let size = OnboardingPage.templateContainerSize(forParentWindowSize: NSSize(width: 1200, height: 900))

        #expect(size == NSSize(width: Self.sheetWidth, height: Self.tallestSheetHeight))
    }

    @Test("in between, the page is 88 % as tall as its window")
    func sizeOnMediumParentWindow() {
        let size = OnboardingPage.templateContainerSize(forParentWindowSize: NSSize(width: 1000, height: 650))
        let expectedHeight: CGFloat = 572
        let heightError = abs(size.height - expectedHeight)

        #expect(size.width == Self.sheetWidth)
        #expect(heightError < 0.001)
    }

    /// The template builds its subviews only when it first draws, so a container left at the size its
    /// `loadView` gives it is 0 × 0, and so is a window or sheet made from it.
    @Test("a window made from the page is the page's size, before anything draws")
    func windowMadeFromContainerHasPageSize() throws {
        let container = try Self.makeContainer()
        let expectedSize = OnboardingPage.templateContainerSize(forParentWindowSize: nil)

        let window = NSWindow(contentViewController: container)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.layoutIfNeeded()

        #expect(container.view.frame.size == expectedSize)
        #expect(window.contentRect(forFrameRect: window.frame).size == expectedSize)
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
