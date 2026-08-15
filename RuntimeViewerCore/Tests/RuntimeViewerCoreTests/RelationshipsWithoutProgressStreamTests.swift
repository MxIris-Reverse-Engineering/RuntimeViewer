import Testing
import Foundation
import RuntimeViewerCore

/// Regression guard for the one hazard Evolution 0007 could not delegate to the
/// compiler.
///
/// Since MachOObjCSection 0003 the library keeps no relationship tables of its
/// own — inheritance and protocol adoption leave it *only* through the event
/// handler. An `ObjCInterfaceIndexer` built without a handler silently keeps
/// nothing, and nothing about that is a compile error.
///
/// `RuntimeObjCSection` used to install its handler only when a progress stream
/// was supplied, which was harmless while the library owned the tables. Six of
/// the seven section-creation call sites pass no progress stream — including
/// `_loadImage(at:)` and background indexing, i.e. how most images are indexed —
/// so leaving that condition in place would empty the Relationships pane for
/// nearly every image, with no error anywhere.
///
/// This test therefore drives the *no-progress-stream* route deliberately:
/// `loadImage(at:)` creates its sections without a continuation.
@Suite("Relationships without a progress stream")
struct RelationshipsWithoutProgressStreamTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    @Test("Images loaded without a progress stream still resolve relationships")
    func relationshipsSurviveWithoutProgressStream() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-rel-no-progress")
        try await engine.connect()

        // `loadImage(at:)` builds its sections with no progress continuation —
        // the route that loses relationship data if the handler is conditional.
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)

        var nsObject: RuntimeObject?
        for imagePath in await engine.loadedImagePaths {
            let objects = try await engine.objects(in: imagePath)
            if let match = objects.first(where: { $0.name == "NSObject" && $0.kind == .objc(.type(.class)) }) {
                nsObject = match
                break
            }
        }
        let anchor = try #require(nsObject, "NSObject not found in the loaded images.")

        let relationships = try await engine.relationships(for: anchor)

        #expect(
            !relationships.subclasses.isEmpty,
            """
            NSObject resolved zero subclasses. The relationship index is only fed \
            by the indexer's event handler, so this is what an unconditionally \
            required handler being installed conditionally looks like — no error, \
            just an empty pane.
            """
        )
        #expect(relationships.subclasses.contains { $0.displayName == "NSString" })
    }

    @Test("ObjC protocol conformers survive without a progress stream")
    func conformersSurviveWithoutProgressStream() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-rel-no-progress-conformers")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.foundationPath)

        let objects = try await engine.objects(in: Anchors.foundationPath)
        let anchor = try #require(
            objects.first(where: { $0.name == "NSCopying" && $0.kind == .objc(.type(.protocol)) }),
            "NSCopying not found in Foundation."
        )

        let relationships = try await engine.relationships(for: anchor)
        #expect(!relationships.conformingTypes.isEmpty)
    }
}
