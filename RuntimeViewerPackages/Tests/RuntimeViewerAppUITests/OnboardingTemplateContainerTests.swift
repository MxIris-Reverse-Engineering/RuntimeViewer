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

    /// With swift-onboardingkit 0.1.0 the page opened as a 0 × 0 window or sheet: the template held itself,
    /// the container and the window at its zero frame. Nothing is put on screen.
    @Test("a window made from the page is the page's size, and the template fills it")
    func windowMadeFromContainerHasPageSize() throws {
        let container = try Self.makeContainer()
        let expectedSize = OBTemplateContainerViewController.sheetSize(forParentWindowSize: nil)

        let window = NSWindow(contentViewController: container)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.layoutIfNeeded()

        #expect(window.contentRect(forFrameRect: window.frame).size == expectedSize)
        #expect(container.view.frame.size == expectedSize)
        #expect(try #require(container.templateView).frame.size == expectedSize)
    }

    /// The standard type's 175-point side margins left the text a column about 130 points wide in the
    /// 482-point page. The template builds its subviews when it first draws; `viewWillDraw()` stands in for
    /// that, so nothing is put on screen.
    @Test("the page's text spans most of its width")
    func textSpansPageWidth() throws {
        let container = try Self.makeContainer()
        let pageSize = OBTemplateContainerViewController.sheetSize(forParentWindowSize: nil)
        let window = NSWindow(contentViewController: container)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let templateView = try #require(container.templateView)

        window.layoutIfNeeded()
        templateView.viewWillDraw()
        window.layoutIfNeeded()

        #expect(templateView.templateType == .centered)
        #expect(templateView.bulletList?.templateType == .centered)
        let titleWidth = try #require(templateView.titleView).frame.width
        let listWidth = try #require(templateView.bulletList).frame.width
        let shortestAcceptableWidth: CGFloat = pageSize.width * 0.6
        #expect(titleWidth > shortestAcceptableWidth)
        #expect(listWidth > shortestAcceptableWidth)
    }

    @Test("a sheet presented from the page is the size its window gives it, and the template fills it")
    func sheetPresentedFromContainerHasPageSize() throws {
        let parentWindowSize = NSSize(width: 1000, height: 650)
        let parentWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: parentWindowSize),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        parentWindow.isReleasedWhenClosed = false
        defer { parentWindow.close() }
        let parentViewController = NSViewController()
        parentViewController.view = NSView(frame: NSRect(origin: .zero, size: parentWindowSize))
        parentWindow.contentViewController = parentViewController
        let container = try Self.makeContainer(parentWindowSize: parentWindow.frame.size)
        let expectedSize = OBTemplateContainerViewController.sheetSize(forParentWindowSize: parentWindow.frame.size)

        parentViewController.presentAsSheet(container)
        defer { parentViewController.dismiss(container) }
        let sheetWindow = try #require(container.view.window)
        sheetWindow.layoutIfNeeded()

        #expect(sheetWindow.contentRect(forFrameRect: sheetWindow.frame).size == expectedSize)
        #expect(try #require(container.templateView).frame.size == expectedSize)
    }

    @Test("the page takes the App Store's style: centered, its rows' symbols in the accent color")
    func pageTakesAppStoreStyle() {
        let templatePage = Self.page.templatePage(parentWindowSize: nil)

        #expect(templatePage.layout == .centered)
        #expect(templatePage.featureTintColor == .controlAccentColor)
        #expect(templatePage.size == OBTemplateContainerViewController.sheetSize(forParentWindowSize: nil))
    }

    @Test("a What's New page has no image above its title")
    func whatsNewPageHasNoImage() throws {
        let templateView = try #require(try Self.makeContainer().templateView)

        #expect(Self.page.templatePage(parentWindowSize: nil).image == nil)
        #expect(templateView.topImageSymbolName == nil)
        #expect(templateView.topImage == nil)
    }

    @Test("the welcome page shows the app's icon, 128 points square")
    func welcomePageShowsAppIcon() throws {
        var welcomePage = Self.page
        welcomePage.kind = .welcome
        welcomePage.image = .appIcon

        guard case .image(let icon) = welcomePage.templatePage(parentWindowSize: nil).image else {
            Issue.record("The welcome page has no image of its own")
            return
        }
        #expect(icon.size == NSSize(width: OnboardingPage.appIconSide, height: OnboardingPage.appIconSide))
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
