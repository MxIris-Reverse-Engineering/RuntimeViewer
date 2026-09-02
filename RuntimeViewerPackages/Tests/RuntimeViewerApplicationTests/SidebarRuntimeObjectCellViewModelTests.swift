import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRuntimeObjectCellViewModel")
@MainActor
struct SidebarRuntimeObjectCellViewModelTests {
    /// Cell ViewModels resolve `appDefaults` for the filter mode, so every one
    /// is built against an isolated store rather than the user's real one.
    private let appDefaults = AppDefaults.isolated()

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
        let phaseViewModel = makeCell(for: phase)
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

    @Test("appending a child that is already present is reported as a no-op")
    func appendingDuplicateChildIsNoOp() throws {
        let child = object(name: "Phase.Value", displayName: "SwiftUI.EventListenerPhase.Value")
        let phaseViewModel = makeCell(for: object(name: "Phase", displayName: "SwiftUI.EventListenerPhase", children: [child]))

        #expect(phaseViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(child) == false)
        #expect(phaseViewModel.children.count == 1)
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
        let manualPhaseViewModel = makeCell(for: manualPhase)
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
        let derivedPhaseViewModel = makeCell(for: derivedPhase)
        let derivedPhaseOfEventViewModel = try #require(derivedPhaseViewModel.children.first)
        let derivedLeaf = try #require(derivedPhaseOfEventViewModel.children.first)

        #expect(manualLeaf.runtimeObject.key == derivedLeaf.runtimeObject.key)
        #expect(manualLeaf.stableID != derivedLeaf.stableID)
    }

    @Test("matchesScopeRecursively accepts a parent whose only match lives in a descendant")
    func scopeMatchesThroughDescendants() throws {
        let innerProtocol = object(name: "Outer.Inner.P", displayName: "Outer.Inner.P", kind: .swift(.type(.protocol)))
        let inner = object(name: "Outer.Inner", displayName: "Outer.Inner", kind: .swift(.type(.class)), children: [innerProtocol])
        let siblingClass = object(name: "Outer.Sibling", displayName: "Outer.Sibling", kind: .swift(.type(.class)))
        let outerViewModel = makeCell(for: object(name: "Outer", displayName: "Outer", kind: .swift(.type(.class)), children: [inner, siblingClass]))

        var protocolsOnly = RuntimeObjectScope()
        protocolsOnly.includedKinds = [.swift(.type(.protocol))]

        #expect(outerViewModel.matchesScopeRecursively(protocolsOnly))
        #expect(makeCell(for: siblingClass).matchesScopeRecursively(protocolsOnly) == false)
    }

    @Test("a text filter context keeps only the children whose subtree names contain the query")
    func textFilterNarrowsChildren() {
        let value = object(name: "Phase.Value", displayName: "SwiftUI.EventListenerPhase.Value")
        let failureReason = object(name: "Phase.FailureReason", displayName: "SwiftUI.EventListenerPhase.FailureReason")
        let phaseViewModel = makeCell(for: object(name: "Phase", displayName: "SwiftUI.EventListenerPhase", children: [failureReason, value]))

        phaseViewModel.filterContext = FilterContext(query: "value", isCaseInsensitive: true, mode: nil)

        #expect(phaseViewModel.children.map(\.runtimeObject.displayName) == ["SwiftUI.EventListenerPhase.Value"])
        #expect(phaseViewModel.filterableString == phaseViewModel.currentAndChildrenNames)

        phaseViewModel.filterContext = FilterContext()
        #expect(phaseViewModel.children.count == 2)
    }

    private func makeCell(for runtimeObject: RuntimeObject) -> SidebarRuntimeObjectCellViewModel {
        withDependencies {
            $0.appDefaults = appDefaults
        } operation: {
            SidebarRuntimeObjectCellViewModel(runtimeObject: runtimeObject, forOpenQuickly: false)
        }
    }

    private func object(
        name: String,
        displayName: String,
        kind: RuntimeObjectKind = .swift(.type(.struct)),
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName,
            kind: kind,
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/SwiftUICore.framework/SwiftUICore",
            children: children,
            properties: properties
        )
    }
}
