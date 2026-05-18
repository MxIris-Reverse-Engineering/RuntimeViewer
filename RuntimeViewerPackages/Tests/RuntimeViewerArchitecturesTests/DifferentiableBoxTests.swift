import Testing
import Foundation
@testable import RuntimeViewerArchitectures

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import DifferenceKit
#endif

@Suite("DifferentiableBox")
struct DifferentiableBoxTests {
    @Test("init stores the model verbatim")
    func storesModel() {
        let box = DifferentiableBox(42)
        #expect(box.model == 42)
    }

    @Test("Hashable + Equatable derived from model")
    func hashableEquatable() {
        let leftBox = DifferentiableBox("alpha")
        let rightBox = DifferentiableBox("alpha")
        let otherBox = DifferentiableBox("beta")

        #expect(leftBox == rightBox)
        #expect(leftBox != otherBox)
        #expect(leftBox.hashValue == rightBox.hashValue)
    }

    @Test("Set deduplicates boxes with equal models")
    func setDeduplication() {
        let boxes: Set<DifferentiableBox<Int>> = [
            DifferentiableBox(1),
            DifferentiableBox(2),
            DifferentiableBox(1),
        ]
        #expect(boxes.count == 2)
        #expect(boxes.contains(DifferentiableBox(1)))
        #expect(boxes.contains(DifferentiableBox(2)))
    }

    @Test("Dictionary keying by box uses model identity")
    func dictionaryKeying() {
        var lookup: [DifferentiableBox<String>: Int] = [:]
        lookup[DifferentiableBox("a")] = 1
        lookup[DifferentiableBox("a")] = 2
        lookup[DifferentiableBox("b")] = 3
        #expect(lookup.count == 2)
        #expect(lookup[DifferentiableBox("a")] == 2)
        #expect(lookup[DifferentiableBox("b")] == 3)
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)

    @Test("differenceIdentifier projects the underlying model")
    func differenceIdentifierIsModel() {
        let box = DifferentiableBox("identity")
        #expect(box.differenceIdentifier == "identity")
    }

    @Test("isContentEqual matches equal models")
    func isContentEqualForEqualModels() {
        let leftBox = DifferentiableBox(7)
        let rightBox = DifferentiableBox(7)
        #expect(leftBox.isContentEqual(to: rightBox))
    }

    @Test("isContentEqual differs when models differ")
    func isContentEqualForDifferentModels() {
        let leftBox = DifferentiableBox(7)
        let rightBox = DifferentiableBox(8)
        #expect(!leftBox.isContentEqual(to: rightBox))
    }

    @Test("DifferenceKit changeset treats equal-model boxes as identical")
    func differenceKitTreatsEqualModelsAsIdentical() {
        let source = [DifferentiableBox(1), DifferentiableBox(2), DifferentiableBox(3)]
        let target = [DifferentiableBox(1), DifferentiableBox(2), DifferentiableBox(3)]
        let changeset = StagedChangeset(source: source, target: target)
        let totalDeltas = changeset.reduce(0) { partial, change in
            partial
                + change.elementInserted.count
                + change.elementDeleted.count
                + change.elementMoved.count
                + change.elementUpdated.count
        }
        #expect(totalDeltas == 0)
    }

    @Test("DifferenceKit detects inserts and deletes via model identity")
    func differenceKitDetectsModelDelta() {
        let source = [DifferentiableBox(1), DifferentiableBox(2)]
        let target = [DifferentiableBox(1), DifferentiableBox(3)]
        let changeset = StagedChangeset(source: source, target: target)
        let inserts = changeset.reduce(0) { $0 + $1.elementInserted.count }
        let deletes = changeset.reduce(0) { $0 + $1.elementDeleted.count }
        #expect(inserts == 1)
        #expect(deletes == 1)
    }

    #endif
}
