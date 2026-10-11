import Foundation
import Testing
@testable import RuntimeViewerCore

/// The candidates of a generic parameter bound to a class are that class and its subclasses in
/// every indexed image, so they grow as images are indexed — and background indexing keeps adding
/// images long after a type was first opened. The type asked about is Foundation's
/// `NSObject.KeyValueObservingPublisher<Subject: NSObject, Value>`; CoreData, indexed after the
/// first request, declares Swift classes that subclass `NSObject` directly, among them
/// `NSCoreDataCodableAdapterRegistry` (read off macOS 27.2).
@Suite("Candidates of a generic parameter bound to a class", .serialized)
struct RuntimeSpecializationClassBoundCandidatesTests {
    private enum Anchors {
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let coreDataPath = "/System/Library/Frameworks/CoreData.framework/CoreData"
    }

    private static func flattened(_ runtimeObjects: [RuntimeObject]) -> [RuntimeObject] {
        runtimeObjects.flatMap { [$0] + flattened($0.children) }
    }

    /// The candidates the engine offers for the publisher's `Subject`, its first parameter.
    private static func subjectCandidates(of publisher: RuntimeObject, in engine: RuntimeEngine) async throws -> [RuntimeSpecializationRequest.Candidate] {
        let request = try await engine.specializationRequest(for: publisher)
        return try #require(request.parameters.first { $0.name == "A" }).candidates
    }

    @Test("a subclass from an image indexed after the first request is offered")
    func subclassFromALaterImageIsOffered() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-class-bound-candidates")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        let objects = Self.flattened(try await engine.objects(in: Anchors.foundationPath))
        let publisher = try #require(objects.first { $0.kind == .swift(.type(.struct)) && $0.displayName.hasSuffix("NSObject.KeyValueObservingPublisher") })

        let candidatesBeforeCoreData = try await Self.subjectCandidates(of: publisher, in: engine)
        try #require(candidatesBeforeCoreData.contains { $0.displayName.hasSuffix("NSKeyValueObservation") }, "Foundation's own NSObject subclasses are not offered")
        try #require(!candidatesBeforeCoreData.contains { $0.imagePath.contains("CoreData.framework") }, "CoreData was indexed before the first request")

        try await engine.loadImage(at: Anchors.coreDataPath)

        let candidatesAfterCoreData = try await Self.subjectCandidates(of: publisher, in: engine)
        #expect(candidatesAfterCoreData.contains { $0.displayName.hasSuffix("NSCoreDataCodableAdapterRegistry") })
    }

    /// What lets requests share the hierarchy instead of each walking every indexed class again:
    /// the aggregate hands out one provider until an image is indexed, and a new one after.
    @Test("the aggregate shares one conformance provider until an image is indexed")
    func conformanceProviderIsSharedUntilAnImageIsIndexed() async throws {
        let factory = RuntimeSwiftSectionFactory()
        let aggregate = await factory.indexer
        let providerBeforeFoundation = aggregate.conformanceProvider
        #expect(aggregate.conformanceProvider === providerBeforeFoundation)

        _ = try await factory.section(for: Anchors.foundationPath)

        #expect(aggregate.conformanceProvider !== providerBeforeFoundation)
    }
}
