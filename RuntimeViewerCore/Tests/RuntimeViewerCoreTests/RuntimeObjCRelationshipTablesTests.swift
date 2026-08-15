import Testing
import Foundation
import ObjCIndexing
@testable import RuntimeViewerCore

/// Unit tests for the reverse tables the application rebuilds from
/// `ObjCIndexingEvent`, after MachOObjCSection 0003 stopped keeping them.
///
/// The end-to-end equivalence is covered by `RelationshipsEquivalenceSnapshotTests`,
/// which compares real output against a baseline captured before the migration.
/// What that snapshot cannot show is *why* the output matches — these tests pin
/// the three properties it depends on, using synthetic events so each one fails
/// in isolation when broken.
///
/// These target `RuntimeObjCRelationshipTables` rather than the indexer that
/// owns it: the properties belong to `fold(_:)`, and testing it directly needs
/// no Mach-O image to parse. Evolution 0008 moved the folding here; the
/// properties themselves are unchanged from 0007, as are these tests.
@Suite("RuntimeObjCRelationshipTables")
struct RuntimeObjCRelationshipTablesTests {
    private static let imagePath = "/fixture/Image.framework/Image"
    private static let categoryImagePath = "/fixture/Other.framework/Other"

    // MARK: - Property 1: both conformance kinds share one table

    @Test("Inline and category adoptions answer the same query")
    func inlineAndCategoryAdoptionsShareOneTable() {
        let tables = RuntimeObjCRelationshipTables()
        tables.fold(.conformanceIndexed(
            className: "InlineAdopter",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        tables.fold(.categoryConformanceIndexed(
            targetClassName: "CategoryAdopter",
            protocolName: "FixtureProtocol",
            imagePath: Self.categoryImagePath,
            targetIsSwiftStable: false
        ))

        let conformers = tables.conformingClasses(toProtocol: "FixtureProtocol")
        // The library wrote both kinds into one dictionary and answered both
        // from a single query. Splitting them into per-case tables would drop
        // half the results here.
        #expect(conformers.map(\.className) == ["InlineAdopter", "CategoryAdopter"])
    }

    // MARK: - Property 2: inline adoptions precede category ones

    @Test("Folding preserves arrival order across both phases")
    func foldingPreservesArrivalOrder() {
        let tables = RuntimeObjCRelationshipTables()
        // The library walks every class before any category, so a consumer
        // folding events in arrival order reproduces that grouping.
        for className in ["ClassA", "ClassB", "ClassC"] {
            tables.fold(.conformanceIndexed(
                className: className,
                protocolName: "FixtureProtocol",
                imagePath: Self.imagePath,
                isSwiftStable: false
            ))
        }
        for targetClassName in ["CategoryTargetA", "CategoryTargetB"] {
            tables.fold(.categoryConformanceIndexed(
                targetClassName: targetClassName,
                protocolName: "FixtureProtocol",
                imagePath: Self.categoryImagePath,
                targetIsSwiftStable: false
            ))
        }

        #expect(
            tables.conformingClasses(toProtocol: "FixtureProtocol").map(\.className)
                == ["ClassA", "ClassB", "ClassC", "CategoryTargetA", "CategoryTargetB"]
        )
    }

    // MARK: - Property 3: dedup keys on all three fields

    @Test("Same class differing only in isSwiftStable is kept twice")
    func dedupKeysOnEveryField() {
        let tables = RuntimeObjCRelationshipTables()
        // A class can reach one protocol twice: inline adoption reads its own
        // `class_t` flag, while a category resolves the target across images and
        // falls back to `false` when that fails. The library's `OrderedSet` kept
        // both entries; collapsing them by class name would look like a fix and
        // would be a behaviour change.
        tables.fold(.conformanceIndexed(
            className: "BridgedClass",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            isSwiftStable: true
        ))
        tables.fold(.categoryConformanceIndexed(
            targetClassName: "BridgedClass",
            protocolName: "FixtureProtocol",
            imagePath: Self.imagePath,
            targetIsSwiftStable: false
        ))

        let conformers = tables.conformingClasses(toProtocol: "FixtureProtocol")
        #expect(conformers.count == 2)
        #expect(conformers.map(\.isSwiftStable) == [true, false])
    }

    @Test("Fully identical records collapse to one")
    func identicalRecordsCollapse() {
        let tables = RuntimeObjCRelationshipTables()
        for _ in 0 ..< 3 {
            tables.fold(.subclassIndexed(
                className: "Subclass",
                superclass: "Superclass",
                imagePath: Self.imagePath,
                isSwiftStable: false
            ))
        }
        #expect(tables.subclasses(of: "Superclass").count == 1)
    }

    // MARK: - Category imagePath asymmetry

    @Test("A category records its own image, not the target class' image")
    func categoryRecordsItsOwnImage() {
        let tables = RuntimeObjCRelationshipTables()
        tables.fold(.categoryConformanceIndexed(
            targetClassName: "NSString",
            protocolName: "FixtureProtocol",
            imagePath: Self.categoryImagePath,
            targetIsSwiftStable: false
        ))

        let conformer = try? #require(tables.conformingClasses(toProtocol: "FixtureProtocol").first)
        // `className` and `imagePath` deliberately do not belong to the same
        // image here. Anything keying off `imagePath` to locate the class will
        // not find it; that is existing behaviour, preserved verbatim.
        #expect(conformer?.className == "NSString")
        #expect(conformer?.imagePath == Self.categoryImagePath)
    }

    // MARK: - Continuous folding

    @Test("Queries interleaved with folding see every event")
    func queryingDoesNotFreezeTheTables() {
        let tables = RuntimeObjCRelationshipTables()
        tables.fold(.subclassIndexed(
            className: "First",
            superclass: "Superclass",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        #expect(tables.subclasses(of: "Superclass").map(\.className) == ["First"])

        // 0007 built its tables lazily on first query and released the event
        // queue at that point, so a query arriving mid-walk had to fold later
        // events in directly or lose them. Folding on arrival removes the
        // hazard rather than handling it — this pins that a query is a pure
        // read, with nothing to invalidate and no ordering it can disturb.
        tables.fold(.subclassIndexed(
            className: "Second",
            superclass: "Superclass",
            imagePath: Self.imagePath,
            isSwiftStable: false
        ))
        #expect(tables.subclasses(of: "Superclass").map(\.className) == ["First", "Second"])
    }

    @Test("Progress events contribute nothing")
    func progressEventsAreIgnored() {
        let tables = RuntimeObjCRelationshipTables()
        tables.fold(.progress(phase: .loadingClasses, itemDescription: "Whatever", currentCount: 1, totalCount: 2))
        #expect(tables.subclasses(of: "Superclass").isEmpty)
        #expect(tables.conformingClasses(toProtocol: "FixtureProtocol").isEmpty)
    }
}
