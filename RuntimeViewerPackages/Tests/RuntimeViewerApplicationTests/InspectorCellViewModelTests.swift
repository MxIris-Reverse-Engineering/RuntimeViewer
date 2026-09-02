import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("InspectorRelationshipsCellViewModel")
@MainActor
struct InspectorRelationshipsCellViewModelTests {
    @Test("title shows the display name and subtitle shows the owning image")
    func titleAndSubtitle() {
        let cell = InspectorRelationshipsCellViewModel(
            runtimeObject: Fixtures.runtimeObject(name: "View", displayName: "SwiftUI.View")
        )

        #expect(cell.appearance.title.string == "SwiftUI.View")
        #expect(cell.appearance.subtitle?.string == "Sample")
    }

    @Test("an object without an image path gets no subtitle")
    func noSubtitleWithoutImage() {
        let cell = InspectorRelationshipsCellViewModel(
            runtimeObject: Fixtures.runtimeObject(name: "Orphan", imagePath: "")
        )

        #expect(cell.appearance.subtitle == nil)
    }

    @Test("the tertiary icon marks generic and specialized objects only")
    func tertiaryIconMarksGenericAndSpecialized() {
        let plain = InspectorRelationshipsCellViewModel(runtimeObject: Fixtures.runtimeObject())
        let generic = InspectorRelationshipsCellViewModel(runtimeObject: Fixtures.runtimeObject(properties: [.isGeneric]))
        let specialized = InspectorRelationshipsCellViewModel(runtimeObject: Fixtures.runtimeObject(properties: [.isSpecialized]))

        #expect(plain.appearance.tertiaryIcon == nil)
        #expect(generic.appearance.tertiaryIcon != nil)
        #expect(specialized.appearance.tertiaryIcon != nil)
    }

    @Test("the secondary icon appears only for objects with a secondary kind")
    func secondaryIconFollowsSecondaryKind() {
        let single = InspectorRelationshipsCellViewModel(runtimeObject: Fixtures.runtimeObject())
        let bridged = InspectorRelationshipsCellViewModel(
            runtimeObject: Fixtures.runtimeObject(kind: .objc(.type(.class)), secondaryKind: .swift(.type(.class)))
        )

        #expect(single.appearance.secondaryIcon == nil)
        #expect(bridged.appearance.secondaryIcon != nil)
    }
}

@Suite("InspectorSwiftSpecializationCellViewModel")
@MainActor
struct InspectorSwiftSpecializationCellViewModelTests {
    @Test("title shows the display name")
    func titleShowsDisplayName() {
        let cell = InspectorSwiftSpecializationCellViewModel(
            runtimeObject: Fixtures.runtimeObject(name: "Box.Int", displayName: "Box<Int>", properties: [.isSpecialized])
        )

        #expect(cell.appearance.title.string == "Box<Int>")
    }

    @Test("the tertiary icon marks generic and specialized objects only")
    func tertiaryIconMarksGenericAndSpecialized() {
        let plain = InspectorSwiftSpecializationCellViewModel(runtimeObject: Fixtures.runtimeObject())
        let generic = InspectorSwiftSpecializationCellViewModel(runtimeObject: Fixtures.runtimeObject(properties: [.isGeneric]))
        let specialized = InspectorSwiftSpecializationCellViewModel(runtimeObject: Fixtures.runtimeObject(properties: [.isSpecialized]))

        #expect(plain.appearance.tertiaryIcon == nil)
        #expect(generic.appearance.tertiaryIcon != nil)
        #expect(specialized.appearance.tertiaryIcon != nil)
    }

    @Test("the secondary icon appears only for objects with a secondary kind")
    func secondaryIconFollowsSecondaryKind() {
        let single = InspectorSwiftSpecializationCellViewModel(runtimeObject: Fixtures.runtimeObject())
        let bridged = InspectorSwiftSpecializationCellViewModel(
            runtimeObject: Fixtures.runtimeObject(kind: .objc(.type(.class)), secondaryKind: .swift(.type(.class)))
        )

        #expect(single.appearance.secondaryIcon == nil)
        #expect(bridged.appearance.secondaryIcon != nil)
    }
}
