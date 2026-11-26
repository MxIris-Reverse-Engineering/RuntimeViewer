import Foundation
import Testing
@testable import RuntimeViewerCore

/// A Find search reads each image under the Generation Options the app prints that image with: an
/// image the query lists in `generationOptionsByImagePath` under its own, every other one under
/// `generationOptions` (proposal `generation-options-image-overrides`).
///
/// Anchored on `NSURLQueryItem` in Foundation, whose `_name` / `_value` ivars are synthesized, so
/// Strip Synthesized Ivars hides them.
@Suite("Find search with per-image Generation Options", .serialized)
struct RuntimeInterfaceSearchImageGenerationOptionsTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    private static var strippingOptions: RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.objcHeaderOptions.stripSynthesizedIvars = true
        return options
    }

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-search-image-options-" + label)
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        _ = try await engine.buildInterfaceCorpus(for: Anchors.foundationPath, transformer: .default)
        _ = try await engine.buildInterfaceCorpus(for: Anchors.libobjcPath, transformer: .default)
        return engine
    }

    private static func ivarLines(
        in engine: RuntimeEngine,
        generationOptions: RuntimeObjectInterface.GenerationOptions?,
        generationOptionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions]?
    ) async throws -> [RuntimeInterfaceSearchMatch] {
        var matches: [RuntimeInterfaceSearchMatch] = []
        _ = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(
            text: "_value",
            matchMode: .matchingWord,
            isCaseSensitive: true,
            generationOptions: generationOptions,
            generationOptionsByImagePath: generationOptionsByImagePath
        )) { batch in
            matches += batch
        }
        return matches.filter { $0.object.name == "NSURLQueryItem" }
    }

    private static func ivarMembers(
        in engine: RuntimeEngine,
        generationOptions: RuntimeObjectInterface.GenerationOptions?,
        generationOptionsByImagePath: [String: RuntimeObjectInterface.GenerationOptions]?
    ) async throws -> [RuntimeMemberMatch] {
        var matches: [RuntimeMemberMatch] = []
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(
            text: "_value",
            matchMode: .matchingWord,
            kinds: [.objcIvar],
            isCaseSensitive: true,
            generationOptions: generationOptions,
            generationOptionsByImagePath: generationOptionsByImagePath
        )) { batch in
            matches += batch
        }
        return matches.filter { $0.object.name == "NSURLQueryItem" }
    }

    @Test("an image the query lists is read under its own options, in both directions")
    func searchProjectsEachImageUnderItsOwnOptions() async throws {
        let engine = try await Self.makeEngine("projection")
        defer { Task { await engine.stop() } }
        let showingOptions = RuntimeObjectInterface.GenerationOptions()

        // Stripped everywhere but Foundation: found.
        #expect(try await !Self.ivarLines(in: engine, generationOptions: Self.strippingOptions, generationOptionsByImagePath: [Anchors.foundationPath: showingOptions]).isEmpty)
        #expect(try await !Self.ivarMembers(in: engine, generationOptions: Self.strippingOptions, generationOptionsByImagePath: [Anchors.foundationPath: showingOptions]).isEmpty)

        // Shown everywhere but Foundation: not found.
        #expect(try await Self.ivarLines(in: engine, generationOptions: showingOptions, generationOptionsByImagePath: [Anchors.foundationPath: Self.strippingOptions]).isEmpty)
        #expect(try await Self.ivarMembers(in: engine, generationOptions: showingOptions, generationOptionsByImagePath: [Anchors.foundationPath: Self.strippingOptions]).isEmpty)

        // Another image's options do not reach Foundation.
        #expect(try await Self.ivarLines(in: engine, generationOptions: Self.strippingOptions, generationOptionsByImagePath: [Anchors.libobjcPath: showingOptions]).isEmpty)
    }

    @Test("a query without the per-image table reads as it did before the table existed")
    func searchWithoutPerImageTableMatchesTodaysResults() async throws {
        let engine = try await Self.makeEngine("without-table")
        defer { Task { await engine.stop() } }

        let strippedWithoutTable = try await Self.ivarLines(in: engine, generationOptions: Self.strippingOptions, generationOptionsByImagePath: nil)
        let strippedWithEmptyTable = try await Self.ivarLines(in: engine, generationOptions: Self.strippingOptions, generationOptionsByImagePath: [:])
        #expect(strippedWithoutTable.isEmpty)
        #expect(strippedWithEmptyTable.isEmpty)

        let shownWithoutTable = try await Self.ivarLines(in: engine, generationOptions: RuntimeObjectInterface.GenerationOptions(), generationOptionsByImagePath: nil)
        #expect(!shownWithoutTable.isEmpty)
    }

    /// A peer of an earlier build sends a query without the key, and reads one with it as if the
    /// key were not there.
    @Test("a query encoded without the per-image table still decodes, and one with it round-trips")
    func queryEncodedWithoutTheTableStillDecodes() throws {
        let query = RuntimeInterfaceSearchQuery(text: "value", generationOptions: Self.strippingOptions)
        var encoded = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(query)) as? [String: Any])
        encoded.removeValue(forKey: "generationOptionsByImagePath")
        let decoded = try JSONDecoder().decode(RuntimeInterfaceSearchQuery.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded == query)
        #expect(decoded.generationOptionsByImagePath == nil)

        let memberQuery = RuntimeMemberSearchQuery(text: "value", generationOptions: Self.strippingOptions, generationOptionsByImagePath: [Anchors.foundationPath: RuntimeObjectInterface.GenerationOptions()])
        let decodedMemberQuery = try JSONDecoder().decode(RuntimeMemberSearchQuery.self, from: JSONEncoder().encode(memberQuery))
        #expect(decodedMemberQuery == memberQuery)
        #expect(decodedMemberQuery.generationOptions(forImageAt: Anchors.foundationPath) == RuntimeObjectInterface.GenerationOptions())
        #expect(decodedMemberQuery.generationOptions(forImageAt: Anchors.libobjcPath) == Self.strippingOptions)
    }
}
