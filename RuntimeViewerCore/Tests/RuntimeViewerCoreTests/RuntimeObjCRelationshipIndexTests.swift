import Testing
import Foundation
import ObjCIndexing
@testable import RuntimeViewerCore

/// Unit tests for the reverse tables Evolution 0007 brought back from
/// MachOObjCSection.
///
/// The end-to-end equivalence is covered by `RelationshipsEquivalenceSnapshotTests`,
/// which compares real output against a baseline captured before the migration.
/// What that snapshot cannot show is *why* the output matches — these tests pin
/// the three properties it depends on, using synthetic events so each one fails
/// in isolation when broken.
@Suite("RuntimeObjCRelationshipIndex")
struct RuntimeObjCRelationshipIndexTests {
    private static let imagePath = "/fixture/Image.framework/Image"
    private static let categoryImagePath = "/fixture/Other.framework/Other"

    // MARK: - Property 1: both conformance kinds share one table

    @Test("Inline and category adoptions answer the same query")
    func inlineAndCategoryAdoptionsShareOneTable() {
        let index = RuntimeObjCRelationshipIndex()
        index.record(.conformanceIndexed(
            className: "InlineAdopter",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        index.record(.categoryConformanceIndexed(
            targetClassName: "CategoryAdopter",
            protocolName: "FixtureProtocol",
            imagePath: Self.categoryImagePath,
            targetIsSwiftStable: false
        ))

        let conformers = index.conformingClasses(toProtocol: "FixtureProtocol")
        // The library wrote both kinds into one dictionary and answered both
        // from a single query. Splitting them into per-case tables would drop
        // half the results here.
        #expect(conformers.map(\.className) == ["InlineAdopter", "CategoryAdopter"])
    }

    // MARK: - Property 2: inline adoptions precede category ones

    @Test("Replay preserves arrival order across both phases")
    func replayPreservesArrivalOrder() {
        let index = RuntimeObjCRelationshipIndex()
        // The library walks every class before any category, so a consumer
        // replaying a single queue in arrival order reproduces that grouping.
        for className in ["ClassA", "ClassB", "ClassC"] {
            index.record(.conformanceIndexed(
                className: className,
                protocolName: "FixtureProtocol",
                imagePath: Self.imagePath,
                isSwiftStable: false
            ))
        }
        for targetClassName in ["CategoryTargetA", "CategoryTargetB"] {
            index.record(.categoryConformanceIndexed(
                targetClassName: targetClassName,
                protocolName: "FixtureProtocol",
                imagePath: Self.categoryImagePath,
                targetIsSwiftStable: false
            ))
        }

        #expect(
            index.conformingClasses(toProtocol: "FixtureProtocol").map(\.className)
                == ["ClassA", "ClassB", "ClassC", "CategoryTargetA", "CategoryTargetB"]
        )
    }

    // MARK: - Property 3: dedup keys on all three fields

    @Test("Same class differing only in isSwiftStable is kept twice")
    func dedupKeysOnEveryField() {
        let index = RuntimeObjCRelationshipIndex()
        // A class can reach one protocol twice: inline adoption reads its own
        // `class_t` flag, while a category resolves the target across images and
        // falls back to `false` when that fails. The library's `OrderedSet` kept
        // both entries; collapsing them by class name would look like a fix and
        // would be a behaviour change.
        index.record(.conformanceIndexed(
            className: "BridgedClass",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            isSwiftStable: true
        ))
        index.record(.categoryConformanceIndexed(
            targetClassName: "BridgedClass",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            targetIsSwiftStable: false
        ))

        let conformers = index.conformingClasses(toProtocol: "FixtureProtocol")
        #expect(conformers.count == 2)
        #expect(conformers.map(\.isSwiftStable) == [true, false])
    }

    @Test("Fully identical records collapse to one")
    func identicalRecordsCollapse() {
        let index = RuntimeObjCRelationshipIndex()
        for _ in 0 ..< 3 {
            index.record(.subclassIndexed(
                className: "Subclass",
                superclass: "Superclass",
                imagePath: Self.imagePath,
                isSwiftStable: false
            ))
        }
        #expect(index.subclasses(of: "Superclass").count == 1)
    }

    // MARK: - Category imagePath asymmetry

    @Test("A category records its own image, not the target class' image")
    func categoryRecordsItsOwnImage() {
        let index = RuntimeObjCRelationshipIndex()
        index.record(.categoryConformanceIndexed(
            targetClassName: "NSString",
            protocolName: "FixtureProtocol",
            imagePath: Self.categoryImagePath,
            targetIsSwiftStable: false
        ))

        let conformer = try? #require(index.conformingClasses(toProtocol: "FixtureProtocol").first)
        // `className` and `imagePath` deliberately do not belong to the same
        // image here. Anything keying off `imagePath` to locate the class will
        // not find it; that is existing behaviour, preserved verbatim by 0007.
        #expect(conformer?.className == "NSString")
        #expect(conformer?.imagePath == Self.categoryImagePath)
    }

    // MARK: - Lazy build

    @Test("Events recorded after the tables were built still register")
    func lateEventsStillRegister() {
        let index = RuntimeObjCRelationshipIndex()
        index.record(.subclassIndexed(
            className: "First",
            superclass: "Superclass",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        // Force materialization, then keep recording. The build releases the
        // pending queue, so a late event has to be folded straight into the
        // tables — rebuilding from an emptied queue would lose "First".
        #expect(index.subclasses(of: "Superclass").map(\.className) == ["First"])

        index.record(.subclassIndexed(
            className: "Second",
            superclass: "Superclass",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        #expect(index.subclasses(of: "Superclass").map(\.className) == ["First", "Second"])
    }

    @Test("prewarm does not change what queries return")
    func prewarmIsObservationallyNeutral() {
        let index = RuntimeObjCRelationshipIndex()
        index.record(.subclassIndexed(
            className: "Subclass",
            superclass: "Superclass",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        index.prewarm()
        #expect(index.subclasses(of: "Superclass").map(\.className) == ["Subclass"])
    }

    @Test("Progress events contribute nothing")
    func progressEventsAreIgnored() {
        let index = RuntimeObjCRelationshipIndex()
        index.record(.progress(phase: .loadingClasses, itemDescription: "Whatever", currentCount: 1, totalCount: 2))
        #expect(index.subclasses(of: "Superclass").isEmpty)
        #expect(index.conformingClasses(toProtocol: "FixtureProtocol").isEmpty)
    }
}
