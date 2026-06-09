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
            displayName: "SwiftUI.EventListenerPhase.FailureReason",
            identityPath: "Phase/FailureReason"
        )
        let value = object(
            name: "Phase.Value",
            displayName: "SwiftUI.EventListenerPhase.Value",
            identityPath: "Phase/Value",
            properties: [.isGeneric]
        )
        let phase = object(
            name: "Phase",
            displayName: "SwiftUI.EventListenerPhase",
            children: [failureReason, value],
            identityPath: "Phase",
            properties: [.isGeneric]
        )
        let phaseViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: phase, forOpenQuickly: false)
        let valueViewModel = try #require(
            phaseViewModel.children.first { $0.runtimeObject.displayName == "SwiftUI.EventListenerPhase.Value" }
        )

        let valueEvent = object(
            name: "Phase.Value.Event",
            displayName: "SwiftUI.EventListenerPhase.Value<SwiftUI.Event>",
            identityPath: "Phase/Value/ValueEvent",
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
                    identityPath: "Phase/PhasePan/FailureReasonPan",
                    properties: [.isSpecialized]
                ),
                object(
                    name: "Phase.PanEvent.Value",
                    displayName: "SwiftUI.EventListenerPhase.Value<SwiftUI.PanEvent>",
                    identityPath: "Phase/PhasePan/ValuePan",
                    properties: [.isSpecialized]
                ),
            ],
            identityPath: "Phase/PhasePan",
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

    private func object(
        name: String,
        displayName: String,
        children: [RuntimeObject] = [],
        identityPath: String,
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName,
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            children: children,
            identityPath: identityPath,
            properties: properties
        )
    }
}
