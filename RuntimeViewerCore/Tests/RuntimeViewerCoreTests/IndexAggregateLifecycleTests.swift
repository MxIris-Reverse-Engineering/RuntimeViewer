import Testing
import Foundation
@testable import RuntimeViewerCore

/// Evolution 0008 restores the cross-image aggregate indexer on the ObjC side so
/// `RuntimeRelationshipsResolver` can ask one question instead of one per image.
/// An aggregate that is only ever added to is a leak: it outlives every section
/// (it lives as long as the owning `RuntimeEngine`), so a registration with no
/// inverse pins that image's entire parsed index for the engine's lifetime, and
/// `removeSection(for:)` frees nothing however carefully it drops its own entry.
///
/// These tests pin the inverse on both sides.
///
/// **They are the only thing exercising this today.** `removeSection` and
/// `removeAllSections` have no production caller on this branch — the teardown
/// that calls them from `RuntimeEngine.stop()` arrives with
/// `feature/node-store-adoption`'s f41648a. Until then the detach is correct but
/// dormant, which is exactly the state a test should hold in place: the next
/// person to wire up teardown gets a working inverse rather than discovering
/// there isn't one.
@Suite("Index aggregate lifecycle")
struct IndexAggregateLifecycleTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    @Test("ObjC: removing a section detaches it from the aggregate")
    func objcRemoveSectionDetachesFromAggregate() async throws {
        let factory = RuntimeObjCSectionFactory()
        _ = try await factory.section(for: Anchors.foundationPath)

        // Foundation contributes plenty of direct NSObject subclasses, and the
        // aggregate can only be answering from the sub-indexer just registered
        // — it parses no image of its own.
        let beforeRemoval = await factory.indexer.subclasses(of: "NSObject")
        #expect(!beforeRemoval.isEmpty, "Aggregate answered nothing while the section was registered.")

        await factory.removeSection(for: Anchors.foundationPath)

        let afterRemoval = await factory.indexer.subclasses(of: "NSObject")
        #expect(afterRemoval.isEmpty, "Aggregate still answers for a section that was removed — the sub-indexer was not detached.")
    }

    @Test("ObjC: removing all sections detaches every one of them")
    func objcRemoveAllSectionsDetachesEverything() async throws {
        let factory = RuntimeObjCSectionFactory()
        _ = try await factory.section(for: Anchors.foundationPath)
        #expect(!(await factory.indexer.subclasses(of: "NSObject")).isEmpty)

        await factory.removeAllSections()

        #expect((await factory.indexer.subclasses(of: "NSObject")).isEmpty)
    }

    @Test("Swift: removing a section detaches it from the aggregate")
    func swiftRemoveSectionDetachesFromAggregate() async throws {
        let factory = RuntimeSwiftSectionFactory()
        let (_, section) = try await factory.section(for: Anchors.foundationPath)

        // Pick a superclass the image actually names, rather than assuming one:
        // which Swift classes the Foundation overlay declares is not something
        // this test should hard-code.
        var superclassKey: String?
        for object in try await section.allObjects() where object.kind == .swift(.type(.class)) {
            if !(await factory.indexer.subclasses(of: object.name)).isEmpty {
                superclassKey = object.name
                break
            }
        }
        let key = try #require(superclassKey, "No Swift class with a direct subclass found in the Foundation overlay.")

        #expect(!(await factory.indexer.subclasses(of: key)).isEmpty)

        await factory.removeSection(for: Anchors.foundationPath)

        #expect(
            (await factory.indexer.subclasses(of: key)).isEmpty,
            "Aggregate still answers for a section that was removed — the sub-indexer was not detached."
        )
    }
}
