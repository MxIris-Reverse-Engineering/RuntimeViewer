import AppKit
import Foundation
import Testing
import Semantic
import RxSwift
import RuntimeViewerCore
import RuntimeViewerSettings
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI
import RuntimeViewerAppTestingSupport

/// The content pane's render stage (proposal `app-core-without-ui-models`): `ContentTextViewModel`
/// prepares the interface and knows no theme; the view's `ContentTextRenderer` themes it off the main
/// thread, again when the theme changes, and nothing at all while only the theme is asked for.
@Suite("Content text renderer")
@MainActor
struct ContentTextRendererTests {
    private static let owner = Fixtures.runtimeObject(name: "SampleOwner", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    /// `class NSObject`, the type token linked to the class it names.
    private static func interface() -> ContentInterface {
        let fetchedInterface = ContentTextViewModel.FetchedInterface(
            interfaceString: SemanticString {
                Standard("class ")
                TypeName(kind: .class, "NSObject")
                Standard(" {}")
            }
            .frozen(),
            runtimeObject: owner,
            commentStructure: nil
        )
        return ContentInterface.prepared(from: fetchedInterface)
    }

    @Test("a font-size change re-themes the interface on screen, without a new one from the view model")
    func rendererRethemesWithoutRefetchingWhenTheFontSizeChanges() async throws {
        let interface = Self.interface()
        let themes = BehaviorSubject(value: ResolvedTheme(preset: .xcode, fontSize: 13))
        let renderer = ContentTextRenderer(interfaces: .just(interface), themes: themes)

        let firstText = try await nextValue(from: renderer.renderedText, timeout: 10)
        #expect(Self.fontSize(of: firstText.attributedString) == 13)

        themes.onNext(ResolvedTheme(preset: .xcode, fontSize: 16))
        let rethemedText = try await nextValue(from: renderer.renderedText, timeout: 10) { Self.fontSize(of: $0.attributedString) == 16 }

        #expect(rethemedText.interface.id == interface.id, "the same interface, themed again")
    }

    /// A theme-only change (⌘+) re-themes in the renderer, where the view model does not see it, so the
    /// renderer's own activity has to cover it for the pane's loading plate to come up.
    @Test("a theme-only change passes through the renderer's own activity")
    func rendererLightsItsOwnPlateForAThemeOnlyChange() async throws {
        let themes = BehaviorSubject(value: ResolvedTheme(preset: .xcode, fontSize: 13))
        let renderer = ContentTextRenderer(interfaces: .just(Self.interface()), themes: themes)
        let disposeBag = DisposeBag()
        // Kept subscribed, as the pane keeps it: the theme change re-themes the interface on screen.
        renderer.renderedText.drive().disposed(by: disposeBag)
        _ = try await nextValue(from: renderer.renderedText, timeout: 10)

        var sawRendering = false
        renderer.isRendering.driveOnNext { isRendering in
            if isRendering { sawRendering = true }
        }
        .disposed(by: disposeBag)
        themes.onNext(ResolvedTheme(preset: .xcode, fontSize: 18))
        _ = try await nextValue(from: renderer.renderedText, timeout: 10) { Self.fontSize(of: $0.attributedString) == 18 }

        #expect(sawRendering, "the re-theming never entered the renderer's activity")
        withExtendedLifetime(disposeBag) {}
    }

    @Test("themed text has each span in the theme's font and colour, links on the linked tokens, and is immutable")
    func themedTextHasTheThemesFontsColoursAndLinks() throws {
        let interface = Self.interface()
        let theme = ResolvedTheme.fallback

        let themedText = interface.attributedString(themedWith: theme)

        #expect(themedText.string == interface.string)
        var utf16Location = 0
        interface.semanticString.enumerateSpans { spanText, type, _ in
            let location = utf16Location
            utf16Location += spanText.utf16.count
            #expect(themedText.attribute(.font, at: location, effectiveRange: nil) as? NSFont == theme.font(for: type))
            #expect(themedText.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor == theme.color(for: type))
        }
        let link = try #require(interface.links.first)
        #expect(themedText.attribute(.link, at: link.range.location, effectiveRange: nil) as? RuntimeObject == link.target)
        #expect(themedText.attribute(.link, at: 0, effectiveRange: nil) == nil)
        // The cross-thread hand-off: the builder's mutable working copy must not leak.
        #expect(!(themedText is NSMutableAttributedString))
    }

    /// The SourceEditor pane reads only the theme: none of its interfaces may be themed.
    @Test("nothing is themed while only the theme is asked for")
    func rendererThemesNothingWhileRenderedTextHasNoSubscriber() async throws {
        let renderer = ContentTextRenderer(interfaces: .just(Self.interface()), themes: .just(.fallback))
        let disposeBag = DisposeBag()
        var sawRendering = false
        renderer.isRendering.driveOnNext { isRendering in
            if isRendering { sawRendering = true }
        }
        .disposed(by: disposeBag)

        _ = try await nextValue(from: renderer.theme, timeout: 10)
        try await Task.sleep(for: .milliseconds(300))

        #expect(!sawRendering)
        withExtendedLifetime(disposeBag) {}
    }

    private static func fontSize(of attributedString: NSAttributedString) -> CGFloat? {
        guard attributedString.length > 0 else { return nil }
        return (attributedString.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize
    }
}
