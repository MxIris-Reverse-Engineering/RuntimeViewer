import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// Find answers from what the content pane shows. The Generation Options
/// that strip an Objective-C member or add a comment decide what a search
/// finds, and a change to them applies from the next search on — the corpus
/// is printed once, with everything, and is not built again.
///
/// Anchored on `NSURLQueryItem` (public since macOS 10.10): both of its
/// properties are synthesized, so `_name` / `_value` are synthesized ivars
/// and `name` / `value` synthesized getters.
@Suite("Find and the Generation Options", .serialized)
@MainActor
struct FindGenerationOptionsTests {
    private static let queryItemClassName = "NSURLQueryItem"

    @Test("what the Generation Options strip is not found, and is found again once they stop stripping it")
    func searchesFollowTheGenerationOptions() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindGenerationOptionsTests.strip", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let documentState = environment.documentState
        let (coordinator, session) = environment.make { (documentState.findCorpusCoordinator, documentState.findSession) }
        defer { withExtendedLifetime(coordinator) {} }

        let built = try await waitForCoverage(of: engine, timeout: 300) { $0.statesByImagePath[TestImages.foundation]?.isBuilt == true }
        let builtState = try #require(built.statesByImagePath[TestImages.foundation])
        #expect(builtState.isBuilt, "Foundation's corpus was never built")

        let queryItem = try #require(try await engine.objects(in: TestImages.foundation).first {
            $0.name == Self.queryItemClassName && $0.kind == .objc(.type(.class))
        })

        // The environment's own store: no other test reads these options.
        let appDefaults = environment.appDefaults
        var strippingOptions = RuntimeObjectInterface.GenerationOptions()
        strippingOptions.objcHeaderOptions.stripSynthesizedIvars = true
        strippingOptions.objcHeaderOptions.stripSynthesizedMethods = true
        appDefaults.options = strippingOptions

        let strippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
        #expect(strippedIvarLines.isEmpty, "the stripped ivar is found: \(strippedIvarLines.map(\.lineText))")

        let strippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
        #expect(!strippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" }, "the stripped ivar is a member match")
        #expect(!strippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" }, "the stripped getter is a member match")
        #expect(strippedMembers.contains { $0.member.kind == .objcProperty && $0.member.name == "value" }, "the property itself is shown and should be found")

        // Every line a search reports is a line the content pane shows.
        var displayOptions = strippingOptions
        displayOptions.transformer = environment.settings.transformer
        let displayedInterface = try #require(try await engine.interface(for: queryItem, options: displayOptions))
        let displayedLines = Set(displayedInterface.interfaceString.string.components(separatedBy: "\n"))
        let valueLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "value", isCaseSensitive: true), with: session))
        #expect(!valueLines.isEmpty)
        for match in valueLines {
            #expect(displayedLines.contains(match.lineText), "not a line the content pane shows: \(match.lineText)")
        }

        // Stop stripping: found at the next search, from the same corpus.
        appDefaults.options = RuntimeObjectInterface.GenerationOptions()
        let unstrippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
        #expect(!unstrippedIvarLines.isEmpty, "the ivar is shown again but not found")
        let unstrippedMembers = Self.memberMatches(in: try await search(FindQuery(mode: .members, text: "value", isCaseSensitive: true), with: session))
        #expect(unstrippedMembers.contains { $0.member.kind == .objcIvar && $0.member.name == "_value" })
        #expect(unstrippedMembers.contains { $0.member.kind == .objcMethod && $0.member.name == "value" })
        #expect(try await engine.interfaceCorpusCoverage().statesByImagePath[TestImages.foundation] == builtState, "the corpus was built again")

        await engine.stop()
    }

    // MARK: - The search on screen, not the query being edited

    /// A Generation Options change runs the search on screen again. It used
    /// to run the query the mode path and the toggles had been edited into
    /// since — Return not pressed — so an edit to a relationship mode left the
    /// text results under the old options, and an edit to Members turned them
    /// into a member search (PR121.39). Both run on the shared engine, whose
    /// Foundation corpus is built once per process.
    @Test("a Generation Options change runs the text search on screen again while the mode path is edited to a relationship mode")
    func optionsChangeRerunsTheShownSearchWhileARelationshipModeIsEdited() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }
        let appDefaults = environment.appDefaults
        var strippingOptions = RuntimeObjectInterface.GenerationOptions()
        strippingOptions.objcHeaderOptions.stripSynthesizedIvars = true
        appDefaults.options = strippingOptions

        let strippedIvarLines = Self.textMatches(in: try await search(FindQuery(mode: .text, text: "_value", isCaseSensitive: true), with: session))
        #expect(strippedIvarLines.isEmpty, "the stripped ivar is found: \(strippedIvarLines.map(\.lineText))")

        // Edited, not run: Return was never pressed.
        session.update { $0.mode = .ancestorTypes }
        appDefaults.options = RuntimeObjectInterface.GenerationOptions()
        try await settleMainQueue()
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        #expect(!Self.textMatches(in: session.results).isEmpty, "the text search on screen was not run again under the new options")
        #expect(session.query.mode == .ancestorTypes, "the edit in progress was overwritten")
    }

    @Test("a Generation Options change keeps a text search on screen a text search while Members is only being edited")
    func optionsChangeKeepsTheShownSearchesMode() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let session = environment.make { environment.documentState.findSession }
        let appDefaults = environment.appDefaults

        _ = try await search(FindQuery(mode: .text, text: "value", isCaseSensitive: true), with: session)
        #expect(!Self.textMatches(in: session.results).isEmpty)

        // Edited, not run.
        session.update { $0.mode = .members }
        var changedOptions = appDefaults.options
        changedOptions.objcHeaderOptions.stripSynthesizedIvars.toggle()
        appDefaults.options = changedOptions
        try await settleMainQueue()
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }

        #expect(!Self.textMatches(in: session.results).isEmpty, "the rerun dropped the text search on screen")
        #expect(Self.memberMatches(in: session.results).isEmpty, "the rerun ran the edited Members query instead")
        #expect(session.query.mode == .members, "the edit in progress was overwritten")
    }

    // MARK: - Helpers

    private func search(_ query: FindQuery, with session: FindSession) async throws -> FindSession.Results {
        session.run(query)
        _ = try await nextValue(from: session.$isSearching.asDriver(), timeout: 60) { !$0 }
        return session.results
    }

    /// The query item's text matches, wherever the tree put them.
    private static func textMatches(in results: FindSession.Results) -> [RuntimeInterfaceSearchMatch] {
        var matches: [RuntimeInterfaceSearchMatch] = []
        func visit(_ node: FindResultNode) {
            if case .textMatch(let match) = node.content, match.object.name == queryItemClassName {
                matches.append(match)
            }
            node.children.forEach(visit)
        }
        results.nodes.forEach(visit)
        return matches
    }

    private static func memberMatches(in results: FindSession.Results) -> [RuntimeMemberMatch] {
        var matches: [RuntimeMemberMatch] = []
        func visit(_ node: FindResultNode) {
            if case .member(let match) = node.content, match.object.name == queryItemClassName {
                matches.append(match)
            }
            node.children.forEach(visit)
        }
        results.nodes.forEach(visit)
        return matches
    }

    private func waitForCoverage(
        of engine: RuntimeEngine,
        timeout: TimeInterval,
        where predicate: @escaping (RuntimeInterfaceCorpusCoverage) -> Bool
    ) async throws -> RuntimeInterfaceCorpusCoverage {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let coverage = try await engine.interfaceCorpusCoverage()
            if predicate(coverage) { return coverage }
            try await Task.sleep(for: .milliseconds(200))
        }
        return try await engine.interfaceCorpusCoverage()
    }
}
