import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// The content pane's half of the Find handshake: a pending highlight on the
/// document is taken once the object's interface is rendered, located in the
/// rendered text, and handed out as a range; a highlight meant for another
/// object is left alone.
@Suite("ContentTextViewModel highlight")
@MainActor
struct ContentTextHighlightTests {
    private let router = MockRouter<ContentRoute>()

    private static let interfaceText = "@interface Foo : NSObject\n- (void)doSomething;\n- (id)initWithFormat:(id)format;\n@end"

    private func makeViewModel(for runtimeObject: RuntimeObject, in environment: ViewModelTestEnvironment) -> (ContentTextViewModel, ContentTextViewModel.Output) {
        let viewModel = environment.make {
            ContentTextViewModel(
                runtimeObject: runtimeObject,
                documentState: environment.documentState,
                router: router,
                interfaceProvider: { runtimeObject, _ in
                    RuntimeObjectInterface(object: runtimeObject, interfaceString: SemanticString(stringLiteral: Self.interfaceText))
                }
            )
        }
        let output = viewModel.transform(.init(runtimeObjectClicked: .empty(), runtimeObjectOpenedInNewTab: .empty()))
        return (viewModel, output)
    }

    @Test("a pending highlight for the shown object is located in the rendered text and taken")
    func highlightIsLocatedAndTaken() async throws {
        let environment = ViewModelTestEnvironment()
        let object = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
        let request = ContentHighlightRequest(
            lineNumber: 3,
            lineText: "- (id)initWithFormat:(id)format; // IMP: 0x1000",
            matchRangeInLine: nil,
            query: "initWithFormat:",
            isCaseSensitive: true
        )
        environment.documentState.selectionRouter.trigger(.pushHighlighting(object, request))
        let (viewModel, output) = makeViewModel(for: object, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let range = try await nextValue(from: output.highlightRange, timeout: 20)
        let expectedLocation = Self.interfaceText.utf16.distance(from: Self.interfaceText.startIndex, to: Self.interfaceText.range(of: "initWithFormat:")!.lowerBound)
        #expect(range == NSRange(location: expectedLocation, length: "initWithFormat:".utf16.count))
        #expect(environment.documentState.pendingContentHighlight == nil)
    }

    @Test("a highlight meant for another object is not consumed")
    func foreignHighlightIsLeftAlone() async throws {
        let environment = ViewModelTestEnvironment()
        let shown = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
        let other = Fixtures.runtimeObject(name: "Bar", kind: .objc(.type(.class)))
        let request = ContentHighlightRequest(lineNumber: 1, lineText: "x", matchRangeInLine: nil, query: "x", isCaseSensitive: false)
        environment.documentState.selectionRouter.trigger(.pushHighlighting(other, request))
        let (viewModel, output) = makeViewModel(for: shown, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        _ = try await nextValue(from: output.attributedString, timeout: 20)
        #expect(try await values(from: output.highlightRange, during: 0.5).isEmpty)
        #expect(environment.documentState.pendingContentHighlight?.object == other)
    }
}
