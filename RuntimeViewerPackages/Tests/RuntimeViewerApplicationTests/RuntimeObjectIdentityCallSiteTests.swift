import AppKit
import DifferenceKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Every place that compares two `RuntimeObject`s, pinned at the seam its
/// caller sees.
///
/// Written as a characterization suite *before* the identity change in the
/// proposal `draft-runtime-object-identity`. Two kinds of assertion live here
/// and they are labelled:
///
/// - **Contract** — behaviour that must survive the change untouched. These are
///   the "did the content change" comparisons.
/// - **Defect** — behaviour the proposal calls a defect, pinned so the change
///   is provably the thing that fixes it. Each one flips exactly once, and the
///   flip is recorded in the proposal's decision log.
///
/// The distinction is not cosmetic: a defect assertion going green after the
/// change would mean the fix did not reach that call site.
@Suite("RuntimeObject identity call sites")
@MainActor
struct RuntimeObjectIdentityCallSiteTests {
    /// The same Objective-C class as the sidebar's authoritative listing has
    /// it, and as an interface link hands it over. They name one type; today
    /// they are not `==`.
    private static let authoritative = Fixtures.runtimeObject(name: "NSView", kind: .objc(.type(.class)))
    private static let payloadWithExtraProperties = Fixtures.runtimeObject(
        name: "NSView",
        kind: .objc(.type(.class)),
        properties: [.isSwiftClass]
    )
    private static let payloadWithQualifiedDisplayName = Fixtures.runtimeObject(
        name: "NSView",
        displayName: "AppKit.NSView",
        kind: .objc(.type(.class))
    )
    private static let payloadWithoutChildren = Fixtures.runtimeObject(name: "Box", kind: .swift(.type(.struct)))
    private static let authoritativeWithChildren = Fixtures.runtimeObject(
        name: "Box",
        kind: .swift(.type(.struct)),
        children: [Fixtures.runtimeObject(name: "Box.Int", kind: .swift(.type(.struct)))],
        properties: [.isGeneric]
    )

    // MARK: - findCell

    /// **Defect.** This is the sidebar highlight that stays behind after a jump.
    @Test("findCell misses the cell when the object carries extra properties")
    func findCellMissesOnPropertiesDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithExtraProperties, in: [cell]) == nil)
    }

    /// **Defect.** The Swift half of the same fault: a link payload's
    /// `displayName` is the qualified name printed from its tokens.
    @Test("findCell misses the cell when the object's displayName differs")
    func findCellMissesOnDisplayNameDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithQualifiedDisplayName, in: [cell]) == nil)
    }

    /// **Defect.** And the third: a payload never carries the children the
    /// authoritative listing has.
    @Test("findCell misses the cell when the object has no children")
    func findCellMissesOnChildrenDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritativeWithChildren, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithoutChildren, in: [cell]) == nil)
    }

    /// **Contract.** The identical object is found — whatever else changes,
    /// this must not.
    @Test("findCell finds the cell for the very object it holds")
    func findCellFindsTheSameObject() throws {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false)
        }

        let lookup = try #require(SidebarRuntimeObjectListViewModel.findCell(for: Self.authoritative, in: [cell]))
        #expect(lookup.cell === cell)
    }

    // MARK: - The cell's runtimeObject didSet

    /// **Contract.** This is how a newly specialized type reaches the sidebar:
    /// the parent cell is handed a copy of itself carrying one more child, and
    /// the `didSet` guard is what decides the tree gets rebuilt. If the guard
    /// ever stops firing here, specialized types stop appearing.
    @Test("assigning a grown runtimeObject rebuilds the children tree")
    func appendedChildRebuildsTheChildrenTree() {
        let environment = ViewModelTestEnvironment()
        let parent = Fixtures.runtimeObject(name: "Box", kind: .swift(.type(.struct)), properties: [.isGeneric])
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: parent, forOpenQuickly: false)
        }
        #expect(cell.children.isEmpty)

        cell.runtimeObject = parent.withAppendedChild(
            Fixtures.runtimeObject(name: "Box.Int", kind: .swift(.type(.struct)), properties: [.isSpecialized])
        )

        #expect(cell.children.map(\.runtimeObject.name) == ["Box.Int"])
    }

    /// **Contract.** The guard's other half: re-assigning an identical object
    /// must not churn the tree. Child cells are reused across a real rebuild,
    /// so instance identity is the observable that separates "did nothing"
    /// from "rebuilt into the same shape".
    @Test("re-assigning an identical runtimeObject keeps the existing child cells")
    func identicalAssignmentKeepsChildCells() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritativeWithChildren, forOpenQuickly: false)
        }
        let childBefore = cell.children.first

        cell.runtimeObject = Self.authoritativeWithChildren

        #expect(cell.children.first === childBefore)
    }

    // MARK: - isContentEqual

    /// **Contract.** DifferenceKit asks this to decide whether a row needs
    /// redrawing. A badge appearing or disappearing is a redraw.
    @Test("sidebar cell reports a properties-only difference as changed content")
    func sidebarCellSeesPropertiesChange() {
        let environment = ViewModelTestEnvironment()
        let (plain, bridged) = environment.make {
            (
                SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false),
                SidebarRuntimeObjectCellViewModel(runtimeObject: Self.payloadWithExtraProperties, forOpenQuickly: false)
            )
        }

        #expect(!plain.isContentEqual(to: bridged))
    }

    /// **Contract.** Same question for the Inspector's two lists.
    @Test("inspector relationships cell reports a properties-only difference as changed content")
    func relationshipsCellSeesPropertiesChange() {
        let plain = InspectorRelationshipsCellViewModel(runtimeObject: Self.authoritative)
        let bridged = InspectorRelationshipsCellViewModel(runtimeObject: Self.payloadWithExtraProperties)

        #expect(!plain.isContentEqual(to: bridged))
    }

    @Test("inspector specialization cell reports a properties-only difference as changed content")
    func specializationCellSeesPropertiesChange() {
        let plain = InspectorSwiftSpecializationCellViewModel(runtimeObject: Self.payloadWithoutChildren)
        let specialized = InspectorSwiftSpecializationCellViewModel(runtimeObject: Self.authoritativeWithChildren)

        #expect(!plain.isContentEqual(to: specialized))
    }

    // MARK: - differenceIdentifier

    /// **Defect.** DifferenceKit treats two rows as the same row when their
    /// difference identifiers match. Today a badge change makes the Inspector
    /// see a *different* row — a delete plus an insert — rather than an update.
    @Test("inspector cells give two identities to one type that differs only in properties")
    func inspectorCellsSplitIdentityOnProperties() {
        let plain = InspectorRelationshipsCellViewModel(runtimeObject: Self.authoritative)
        let bridged = InspectorRelationshipsCellViewModel(runtimeObject: Self.payloadWithExtraProperties)

        #expect(plain.differenceIdentifier != bridged.differenceIdentifier)
    }

    // MARK: - DocumentState

    /// **Defect.** Two forms of one type make two timeline entries, so a single
    /// step back returns to the type you are already looking at.
    @Test("pushing two forms of one type records two timeline entries")
    func timelineRecordsBothFormsOfOneType() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.authoritative))
        documentState.selectionRouter.trigger(.push(Self.payloadWithExtraProperties))

        #expect(documentState.selectionStack.count == 2)
    }

    /// **Contract.** Pushing the very same object twice must stay one entry —
    /// this is the behaviour the defect above fails to extend to the type's
    /// other form.
    @Test("pushing the identical object twice records one timeline entry")
    func timelineCollapsesAnIdenticalPush() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.authoritative))
        documentState.selectionRouter.trigger(.push(Self.authoritative))

        #expect(documentState.selectionStack.count == 1)
    }

    /// **Contract.** The active tab follows the selection either way; what the
    /// identity change alters is only how many redundant writes happen on the
    /// way, which is not observable here.
    @Test("the active tab tracks the pushed object")
    func activeTabTracksTheSelection() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.authoritative))

        #expect(documentState.tabs[documentState.activeTabIndex].object == Self.authoritative)
    }

    // MARK: - The panes' "same object, do not refetch" guards

    private let inspectorRouter = MockRouter<InspectorRuntimeObjectRoute>()
    private let selectRelationshipRelay = PublishRelay<InspectorRelationshipsCellViewModel>()
    private let addSpecializationRelay = PublishRelay<Void>()
    private let selectSpecializationRelay = PublishRelay<InspectorSwiftSpecializationCellViewModel>()

    /// **Defect.** `update(for:)` is supposed to be a no-op when the pane is
    /// already showing that type. Handed the same type in its other form, the
    /// guard lets it through and the pane refetches — visibly, because the
    /// loading placeholder flashes over content that was already correct.
    @Test("the class pane refetches when handed the same type carrying extra properties")
    func classPaneRefetchesOnPropertiesDifference() async throws {
        let environment = ViewModelTestEnvironment()
        let viewModel = environment.make {
            InspectorClassViewModel(
                runtimeObject: Self.authoritative,
                documentState: environment.documentState,
                router: inspectorRouter
            )
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(.init())
        _ = try await nextValue(from: output.hierarchyState) { state in
            if case .loaded = state { return true }
            return false
        }

        async let emissions = values(from: output.hierarchyState.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: Self.payloadWithExtraProperties)

        #expect(try await !emissions.isEmpty)
    }

    /// **Contract.** The very same object must not refetch. This is the half
    /// that already works, and it has to keep working.
    @Test("the class pane does not refetch when handed the identical object")
    func classPaneDoesNotRefetchOnIdenticalObject() async throws {
        let environment = ViewModelTestEnvironment()
        let viewModel = environment.make {
            InspectorClassViewModel(
                runtimeObject: Self.authoritative,
                documentState: environment.documentState,
                router: inspectorRouter
            )
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(.init())
        _ = try await nextValue(from: output.hierarchyState) { state in
            if case .loaded = state { return true }
            return false
        }

        async let emissions = values(from: output.hierarchyState.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: Self.authoritative)

        #expect(try await emissions.isEmpty)
    }

    /// **Defect.** Same guard, relationships pane.
    @Test("the relationships pane refetches when handed the same type carrying extra properties")
    func relationshipsPaneRefetchesOnPropertiesDifference() async throws {
        let environment = ViewModelTestEnvironment()
        let viewModel = environment.make {
            InspectorRelationshipsViewModel(
                runtimeObject: Self.authoritative,
                documentState: environment.documentState,
                router: inspectorRouter
            )
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(.init(selectRelationshipClicked: selectRelationshipRelay.asSignal()))
        _ = try await nextValue(from: output.state) { state in
            if case .loaded = state { return true }
            return false
        }

        async let emissions = values(from: output.state.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: Self.payloadWithExtraProperties)

        #expect(try await !emissions.isEmpty)
    }

    /// **Defect.** Same guard, specialization pane. Its rows come off a
    /// synchronous map over the object, so no load has to settle first.
    @Test("the specialization pane rebuilds its rows when handed the same type carrying extra properties")
    func specializationPaneRebuildsOnPropertiesDifference() async throws {
        let environment = ViewModelTestEnvironment()
        let viewModel = environment.make {
            InspectorSwiftSpecializationViewModel(
                runtimeObject: Self.authoritativeWithChildren,
                documentState: environment.documentState,
                router: inspectorRouter
            )
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(
            .init(
                addSpecializationClicked: addSpecializationRelay.asSignal(),
                selectSpecializationClicked: selectSpecializationRelay.asSignal()
            )
        )
        let grownWithExtraProperties = Fixtures.runtimeObject(
            name: "Box",
            kind: .swift(.type(.struct)),
            children: Self.authoritativeWithChildren.children,
            properties: [.isGeneric, .isSwiftClass]
        )

        async let emissions = values(from: output.specializedChildren.skip(1), during: 0.5)
        try await settleMainQueue()
        viewModel.update(for: grownWithExtraProperties)

        #expect(try await !emissions.isEmpty)
    }
}
