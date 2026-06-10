import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRuntimeObjectCellViewModel")
@MainActor
struct SidebarRuntimeObjectCellViewModelTests {
    @Test("ancestor specialization preserves existing nested specialization")
    func ancestorSpecializationPreservesExistingNestedSpecialization() throws {
        let failureReason = object(
            name: "Phase.FailureReason",
            displayName: "SwiftUI.EventListenerPhase.FailureReason"
        )
        let value = object(
            name: "Phase.Value",
            displayName: "SwiftUI.EventListenerPhase.Value",
            properties: [.isGeneric]
        )
        let phase = object(
            name: "Phase",
            displayName: "SwiftUI.EventListenerPhase",
            children: [failureReason, value],
            properties: [.isGeneric]
        )
        let phaseViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: phase, forOpenQuickly: false)
        let valueViewModel = try #require(
            phaseViewModel.children.first { $0.runtimeObject.displayName == "SwiftUI.EventListenerPhase.Value" }
        )

        let valueEvent = object(
            name: "Phase.Value.Event",
            displayName: "SwiftUI.EventListenerPhase.Value<SwiftUI.Event>",
            properties: [.isSpecialized]
        )
        valueViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(valueEvent)

        let phasePan = object(
            name: "Phase.PanEvent",
            displayName: "SwiftUI.EventListenerPhase<SwiftUI.PanEvent>",
            children: [
                object(
                    name: "Phase.PanEvent.FailureReason",
                    displayName: "SwiftUI.EventListenerPhase.FailureReason<SwiftUI.PanEvent>",
                    properties: [.isSpecialized]
                ),
                object(
                    name: "Phase.PanEvent.Value",
                    displayName: "SwiftUI.EventListenerPhase.Value<SwiftUI.PanEvent>",
                    properties: [.isSpecialized]
                ),
            ],
            properties: [.isSpecialized]
        )
        phaseViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(phasePan)

        let materializedPhase = phaseViewModel.materializedRuntimeObject()
        let originalValue = try #require(
            materializedPhase.children.first { $0.displayName == "SwiftUI.EventListenerPhase.Value" }
        )

        #expect(originalValue.children.map(\.displayName) == ["SwiftUI.EventListenerPhase.Value<SwiftUI.Event>"])
        #expect(materializedPhase.children.contains { $0.displayName == "SwiftUI.EventListenerPhase<SwiftUI.PanEvent>" })
    }

    @Test("StableID distinguishes same RuntimeObject under different sidebar parents")
    func stableIDDistinguishesSameObjectUnderDifferentParents() throws {
        // Same Swift metadata `Value<Event>` reachable via two routes:
        //   * manually specializing the inner `Value` generic     → Phase / Value / Value<Event>
        //   * auto-derived when outer `Phase<Event>` is specialized → Phase / Phase<Event> / Value
        // The sidebar wants both to coexist as distinct rows, so their cell
        // viewmodels MUST hash to different StableIDs even though the
        // underlying RuntimeObject's (imagePath, name, kind) tuple is identical.
        let valueOfEvent = object(
            name: "Phase.Value.Event",
            displayName: "SwiftUI.EventListenerPhase.Value<SwiftUI.Event>",
            properties: [.isSpecialized]
        )

        let manualValueGeneric = object(
            name: "Phase.Value",
            displayName: "SwiftUI.EventListenerPhase.Value",
            children: [valueOfEvent],
            properties: [.isGeneric]
        )
        let manualPhase = object(
            name: "Phase",
            displayName: "SwiftUI.EventListenerPhase",
            children: [manualValueGeneric],
            properties: [.isGeneric]
        )
        let manualPhaseViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: manualPhase, forOpenQuickly: false)
        let manualValueViewModel = try #require(manualPhaseViewModel.children.first)
        let manualLeaf = try #require(manualValueViewModel.children.first)

        let derivedPhaseOfEvent = object(
            name: "Phase.Event",
            displayName: "SwiftUI.EventListenerPhase<SwiftUI.Event>",
            children: [valueOfEvent],
            properties: [.isSpecialized]
        )
        let derivedPhase = object(
            name: "Phase",
            displayName: "SwiftUI.EventListenerPhase",
            children: [derivedPhaseOfEvent],
            properties: [.isGeneric]
        )
        let derivedPhaseViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: derivedPhase, forOpenQuickly: false)
        let derivedPhaseOfEventViewModel = try #require(derivedPhaseViewModel.children.first)
        let derivedLeaf = try #require(derivedPhaseOfEventViewModel.children.first)

        #expect(manualLeaf.runtimeObject.key == derivedLeaf.runtimeObject.key)
        #expect(manualLeaf.stableID != derivedLeaf.stableID)
    }

    private func object(
        name: String,
        displayName: String,
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName,
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            children: children,
            properties: properties
        )
    }
}
