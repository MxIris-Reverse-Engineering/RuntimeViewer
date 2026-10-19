import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// The content pane's side of the cross-reference commands: which lines carry which member, what a
/// command chosen there does, and the member at the insertion point that the Inspector and the main
/// menu follow.
@Suite("Content pane cross references", .serialized)
@MainActor
struct ContentCrossReferenceTests {
    private let router = MockRouter<ContentRoute>()
    private let crossReferenceRequestedRelay = PublishRelay<FindCrossReferenceRequest>()
    private let cursorMemberChangedRelay = PublishRelay<RuntimeMemberReference?>()

    private static let foo = Fixtures.runtimeObject(name: "Foo", kind: .objc(.type(.class)))

    /// ```
    /// @interface Foo : NSObject {      1
    ///     id _delegate;                2
    /// }                                3
    /// @property id delegate;           4
    /// - (void)doSomething:(id)thing;   5
    /// @end                             6
    /// ```
    private static let interfaceString = SemanticString {
        Keyword("@interface")
        Standard(" Foo : NSObject {\n    id ")
        Variable("_delegate")
        Standard(";\n}\n")
        Keyword("@property")
        Standard(" id ")
        MemberDeclaration("delegate")
        Standard(";\n- (void)")
        FunctionDeclaration("doSomething")
        Standard(":(id)thing;\n")
        Keyword("@end")
    }

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (ContentTextViewModel, ContentTextViewModel.Output) {
        let viewModel = environment.make {
            ContentTextViewModel(
                runtimeObject: Self.foo,
                documentState: environment.documentState,
                router: router,
                interfaceProvider: { runtimeObject, _ in
                    RuntimeObjectInterface(object: runtimeObject, interfaceString: Self.interfaceString)
                }
            )
        }
        let output = viewModel.transform(.init(
            runtimeObjectClicked: .empty(),
            runtimeObjectOpenedInNewTab: .empty(),
            crossReferenceRequested: crossReferenceRequestedRelay.asSignal(),
            cursorMemberChanged: cursorMemberChangedRelay.asSignal()
        ))
        return (viewModel, output)
    }

    /// The member the rendered text says line `lineNumber` declares.
    private static func declaredMember(onLine lineNumber: Int, of attributedString: NSAttributedString) -> RuntimeMemberReference? {
        let lines = attributedString.string.components(separatedBy: "\n")
        let lineStart = lines.prefix(lineNumber - 1).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return attributedString.attribute(.runtimeViewerDeclaredMember, at: lineStart, effectiveRange: nil) as? RuntimeMemberReference
    }

    @Test("a line declaring a member with code carries the member, over the whole line; an ivar's line carries none")
    func renderedTextCarriesDeclaredMembers() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rendered = try await nextValue(from: output.renderedInterface, timeout: 30).attributedString

        #expect(Self.declaredMember(onLine: 4, of: rendered) == RuntimeMemberReference(object: Self.foo, name: "delegate", kind: .objcProperty, isStatic: false))
        #expect(Self.declaredMember(onLine: 5, of: rendered) == RuntimeMemberReference(object: Self.foo, name: "doSomething:", kind: .objcMethod, isStatic: false))
        #expect(Self.declaredMember(onLine: 2, of: rendered) == nil, "an ivar has no code")
        #expect(Self.declaredMember(onLine: 1, of: rendered) == nil)
        // The whole line: the name is not where a right-click has to land.
        let methodLineEnd = (rendered.string as NSString).range(of: "thing;").location
        #expect(rendered.attribute(.runtimeViewerDeclaredMember, at: methodLineEnd, effectiveRange: nil) as? RuntimeMemberReference == Self.declaredMember(onLine: 5, of: rendered))
    }

    @Test("a command chosen in the content pane runs in the Find navigator, recorded, and asks for the navigator")
    func commandsRunInTheFindNavigator() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        // Made inside the environment, so it records into the environment's defaults.
        let session = environment.make { environment.documentState.findSession }
        var showRequestCount = 0
        let subscription = session.showResultsRequested.emitOnNext { showRequestCount += 1 }
        defer { subscription.dispose() }
        let member = RuntimeMemberReference(object: Self.foo, name: "doSomething:", kind: .objcMethod, isStatic: false)

        crossReferenceRequestedRelay.accept(FindCrossReferenceRequest(mode: .callees, root: .member(member, declaration: nil)))

        #expect(session.query.mode == .callees)
        #expect(session.query.crossReferenceRoot == .member(member, declaration: nil))
        #expect(session.query.term.plainText == "-[Foo doSomething:]")
        #expect(showRequestCount == 1)
        let recentQueries = environment.appDefaults.findRecentQueriesByScope.values.flatMap { $0 }
        #expect(recentQueries.contains { $0.crossReferenceRoot == .member(member, declaration: nil) })
    }

    @Test("the insertion point's member is the shown object's member, or none")
    func cursorMemberBelongsToTheShownObject() async throws {
        let environment = ViewModelTestEnvironment()
        let (viewModel, _) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = RuntimeMemberReference(object: Self.foo, name: "doSomething:", kind: .objcMethod, isStatic: false)
        let otherMember = RuntimeMemberReference(object: Fixtures.runtimeObject(name: "Bar", kind: .objc(.type(.class))), name: "doSomething:", kind: .objcMethod, isStatic: false)

        cursorMemberChangedRelay.accept(member)
        #expect(environment.documentState.cursorMember == member)

        cursorMemberChangedRelay.accept(otherMember)
        #expect(environment.documentState.cursorMember == nil, "a late event from another object's text")

        cursorMemberChangedRelay.accept(member)
        cursorMemberChangedRelay.accept(nil)
        #expect(environment.documentState.cursorMember == nil)
    }

    @Test("the main menu's commands act on the insertion point's member and on the type on screen")
    func mainMenuCommandsFollowTheDocument() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let member = RuntimeMemberReference(object: Self.foo, name: "doSomething:", kind: .objcMethod, isStatic: false)
        #expect(documentState.crossReferenceRequest(.callHierarchy) == nil, "nothing is shown")
        #expect(documentState.crossReferenceRequest(.typeReferences) == nil)

        documentState.selectionRouter.trigger(.push(Self.foo))
        #expect(documentState.crossReferenceRequest(.typeReferences) == FindCrossReferenceRequest(mode: .typeReferences, root: .type(Self.foo)))
        #expect(documentState.crossReferenceRequest(.callHierarchy) == nil, "the insertion point is on no member")

        documentState.updateCursorMember(member)
        #expect(documentState.crossReferenceRequest(.callHierarchy) == FindCrossReferenceRequest(mode: .callHierarchy, root: .member(member, declaration: nil)))
        #expect(documentState.crossReferenceRequest(.callees) == FindCrossReferenceRequest(mode: .callees, root: .member(member, declaration: nil)))

        // Another object on screen: the member left behind does not count.
        documentState.selectionRouter.trigger(.push(Fixtures.runtimeObject(name: "Bar", kind: .objc(.type(.protocol)))))
        #expect(documentState.crossReferenceRequest(.callHierarchy) == nil)
        #expect(documentState.crossReferenceRequest(.typeReferences) == nil, "a protocol is no type whose references are found")
    }
}
