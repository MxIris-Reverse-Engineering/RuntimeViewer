import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// The content pane's half of the Find handshake: the request a navigation
/// builds the ViewModel with is located in the rendered text once and handed
/// out as a range; a request no ViewModel was built with goes nowhere.
@Suite("ContentTextViewModel highlight")
@MainActor
struct ContentTextHighlightTests {
    private let router = MockRouter<ContentRoute>()

    private static let interfaceText = "@interface Foo : NSObject\n- (void)doSomething;\n- (id)initWithFormat:(id)format;\n@end"

    private func makeViewModel(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, in environment: ViewModelTestEnvironment) -> (ContentTextViewModel, ContentTextViewModel.Output) {
        let viewModel = environment.make {
            ContentTextViewModel(
                runtimeObject: runtimeObject,
                highlightRequest: highlightRequest,
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

    @Test("the request a ViewModel is built with is located in the rendered text")
    func requestIsLocatedOnTheFirstRender() async throws {
        let environment = ViewModelTestEnvironment()
        let object = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
        let request = ContentHighlightRequest(
            lineNumber: 3,
            lineText: "- (id)initWithFormat:(id)format; // IMP: 0x1000",
            matchRangeInLine: nil,
            query: "initWithFormat:",
            isCaseSensitive: true
        )
        let (viewModel, output) = makeViewModel(for: object, highlightRequest: request, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let range = try await nextValue(from: output.highlightRange, timeout: 20)
        let expectedLocation = Self.interfaceText.utf16.distance(from: Self.interfaceText.startIndex, to: Self.interfaceText.range(of: "initWithFormat:")!.lowerBound)
        #expect(range == NSRange(location: expectedLocation, length: "initWithFormat:".utf16.count))
    }

    @Test("a highlight left behind by a navigation that moved on never reaches a later visit")
    func abandonedHighlightNeverReachesALaterVisit() async throws {
        let environment = ViewModelTestEnvironment()
        let abandoned = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))
        let request = ContentHighlightRequest(lineNumber: 3, lineText: "- (id)initWithFormat:(id)format;", matchRangeInLine: nil, query: "initWithFormat:", isCaseSensitive: true)
        // A hit in Foo clicked, then Bar before Foo's interface ever rendered.
        environment.documentState.selectionRouter.trigger(.pushHighlighting(abandoned, request))
        environment.documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "Bar", kind: .objc(.type(.class)))))

        // Foo again later, from the sidebar: a plain visit.
        let (viewModel, output) = makeViewModel(for: abandoned, in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        // Subscribed before the render, so a range located right after it is not missed.
        var highlightRanges: [NSRange] = []
        let subscription = output.highlightRange.emitOnNext { highlightRanges.append($0) }
        defer { subscription.dispose() }

        _ = try await nextValue(from: output.attributedString, timeout: 20) { $0 != nil }
        try await Task.sleep(for: .milliseconds(500))
        #expect(highlightRanges.isEmpty)
    }
}
