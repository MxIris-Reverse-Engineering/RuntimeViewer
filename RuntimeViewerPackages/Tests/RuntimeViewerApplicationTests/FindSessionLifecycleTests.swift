import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The Find session against the life of its document: a session may outlive
/// its document while an engine call holds it, and must then neither read the
/// document nor start a search of its own.
@Suite("FindSession lifecycle", .serialized)
@MainActor
struct FindSessionLifecycleTests {
    @Test("a session that outlives its document ignores a Generation Options change")
    func sessionOutlivingItsDocumentIgnoresOptionsChange() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment()

        var documentState: DocumentState? = DocumentState(runtimeEngine: engine)
        weak let releasedDocumentState = documentState
        // Built inside `make` so the session's `@Dependency` takes the
        // environment's isolated `AppDefaults`.
        let session = try environment.make { try #require(documentState).findSession }
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        #expect(session.results.summary != nil, "a search on screen is what a Generation Options change runs again")

        // The session stays alive the way an engine call that cannot be
        // cancelled keeps it alive; the document goes.
        documentState = nil
        #expect(releasedDocumentState == nil)

        var changedOptions = environment.appDefaults.options
        changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        environment.appDefaults.options = changedOptions
        try await settleMainQueue()

        // Before the fix the rerun read the freed document through `unowned`
        // and the process aborted here.
        #expect(session.isSearching == false)
    }

    @Test("after its document closes, a session starts no search on a Generation Options change")
    func closedSessionStartsNoSearch() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }
        session.run(FindQuery(mode: .text, text: "NSObject"))
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        let resultsBeforeClose = session.results

        session.documentWillClose()

        var changedOptions = environment.appDefaults.options
        changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        environment.appDefaults.options = changedOptions

        let searchingStates = try await values(from: session.$isSearching.asDriver(), during: 1)
        #expect(!searchingStates.contains(true), "a Generation Options change started a search after the document closed")
        #expect(session.results == resultsBeforeClose)
    }
}
