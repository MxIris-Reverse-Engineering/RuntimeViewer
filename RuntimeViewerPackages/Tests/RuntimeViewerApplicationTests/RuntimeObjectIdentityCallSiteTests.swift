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
        children: [Fixtures.runtimeObject(name: "Box.Int", kind: .swift(.type(.struct)), properties: [.isSpecialized])],
        properties: [.isGeneric]
    )

    // MARK: - findCell

    /// **Fixed.** This was the sidebar highlight that stayed behind after a
    /// jump: the link payload carried a badge the sidebar's own listing did not.
    @Test("findCell finds the cell when the object carries extra properties")
    func findCellFindsDespitePropertiesDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithExtraProperties, in: [cell])?.cell === cell)
    }

    /// **Fixed.** The Swift half of the same fault: a link payload's
    /// `displayName` is the qualified name printed from its tokens.
    @Test("findCell finds the cell when the object's displayName differs")
    func findCellFindsDespiteDisplayNameDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritative, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithQualifiedDisplayName, in: [cell])?.cell === cell)
    }

    /// **Fixed.** And the third: a payload never carries the children the
    /// authoritative listing has.
    @Test("findCell finds the cell when the object has no children")
    func findCellFindsDespiteChildrenDifference() {
        let environment = ViewModelTestEnvironment()
        let cell = environment.make {
            SidebarRuntimeObjectCellViewModel(runtimeObject: Self.authoritativeWithChildren, forOpenQuickly: false)
        }

        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Self.payloadWithoutChildren, in: [cell])?.cell === cell)
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

    /// **Fixed.** DifferenceKit treats two rows as the same row when their
    /// difference identifiers match. A badge change is now an update of one
    /// row rather than a delete plus an insert of two different ones.
    @Test("inspector cells give one identity to one type whatever its properties")
    func inspectorCellsKeepOneIdentityAcrossProperties() {
        let plain = InspectorRelationshipsCellViewModel(runtimeObject: Self.authoritative)
        let bridged = InspectorRelationshipsCellViewModel(runtimeObject: Self.payloadWithExtraProperties)

        #expect(plain.differenceIdentifier == bridged.differenceIdentifier)
    }

    // MARK: - DocumentState

    /// **Fixed.** Two forms of one type used to make two timeline entries, so
    /// a single step back returned to the type already on screen.
    @Test("pushing two forms of one type records one timeline entry")
    func timelineCollapsesBothFormsOfOneType() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.authoritative))
        documentState.selectionRouter.trigger(.push(Self.payloadWithExtraProperties))

        #expect(documentState.selectionStack.count == 1)
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

    /// **Contract.** The active tab follows the selection. Which *form* of a
    /// type it holds once two forms have met is pinned separately, below.
    @Test("the active tab tracks the pushed object")
    func activeTabTracksTheSelection() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.authoritative))

        #expect(documentState.tabs[documentState.activeTabIndex].object == Self.authoritative)
    }

    /// **Contract.** One entry per type, but that entry holds the form now on
    /// screen. Missed by the first pass of this suite, which pinned only the
    /// count: with identity `==` the second push neither appended nor replaced,
    /// so the timeline kept the link payload while `selectedRuntimeObject`
    /// showed the authoritative form, and stepping back or forward brought the
    /// payload back — for a generic type, without its specialization tab.
    @Test("the timeline entry carries the form of the type pushed last")
    func timelineEntryCarriesTheLatestForm() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.payloadWithQualifiedDisplayName))
        documentState.selectionRouter.trigger(.push(Self.authoritative))

        #expect(documentState.selectionStack.map(\.displayName) == ["NSView"])
    }

    /// **Contract.** The same for the active tab, whose title is the held
    /// object's `displayName` and which a tab switch hands back to the panes.
    @Test("the active tab carries the form of the type pushed last")
    func activeTabCarriesTheLatestForm() {
        let documentState = DocumentState()

        documentState.selectionRouter.trigger(.push(Self.payloadWithQualifiedDisplayName))
        documentState.selectionRouter.trigger(.push(Self.authoritative))

        #expect(documentState.tabs[documentState.activeTabIndex].title == "NSView")
    }

    // MARK: - The panes' "same object, do not refetch" guards

    private let inspectorRouter = MockRouter<InspectorRuntimeObjectRoute>()
    private let selectRelationshipRelay = PublishRelay<InspectorRelationshipsCellViewModel>()
    private let addSpecializationRelay = PublishRelay<Void>()
    private let selectSpecializationRelay = PublishRelay<InspectorSwiftSpecializationCellViewModel>()

    /// **Fixed.** `update(for:)` is a no-op when the pane already shows that
    /// type — including when the type arrives in its other form. Before, the
    /// guard let it through and the loading placeholder flashed over content
    /// that was already correct.
    @Test("the class pane does not refetch when handed the same type carrying extra properties")
    func classPaneDoesNotRefetchOnPropertiesDifference() async throws {
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

        #expect(try await emissions.isEmpty)
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

    /// **Fixed.** Same guard, relationships pane.
    @Test("the relationships pane does not refetch when handed the same type carrying extra properties")
    func relationshipsPaneDoesNotRefetchOnPropertiesDifference() async throws {
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

        #expect(try await emissions.isEmpty)
    }

    /// **Flipped back by the review of the identity change.** The identity
    /// change had made this "does not rebuild" and pinned it as a fix next to
    /// the two panes above. It was not one: those two fetch and flash a
    /// placeholder, this one does neither, because its rows are a synchronous
    /// map over `runtimeObject.children`. It now guards on content, so that a
    /// type which has grown a specialization reaches it (the next test), and
    /// the same type arriving with other properties therefore rebuilds the
    /// rows. What has to hold is that they are the rows it already showed.
    @Test("the specialization pane rebuilds the same rows when handed the same type carrying extra properties")
    func specializationPaneRebuildsTheSameRowsOnPropertiesDifference() async throws {
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
        let sameTypeWithExtraProperties = Fixtures.runtimeObject(
            name: "Box",
            kind: .swift(.type(.struct)),
            children: Self.authoritativeWithChildren.children,
            properties: [.isGeneric, .isSwiftClass]
        )
        let rowsBefore = try await nextValue(from: output.specializedChildren)

        async let rebuiltRows = nextValue(from: output.specializedChildren.skip(1), timeout: 2)
        try await settleMainQueue()
        viewModel.update(for: sameTypeWithExtraProperties)

        #expect(try await rebuiltRows.map(\.runtimeObject.name) == rowsBefore.map(\.runtimeObject.name))
        #expect(!rowsBefore.isEmpty)
    }

    /// **Contract.** Of the three panes, this is the one whose rows *are* the
    /// object's content — its specialized `children` — so a type that has grown
    /// a specialization since the pane last saw it is the same type in a new
    /// state, and the new row has to appear.
    ///
    /// Missed by the first pass of this suite. It is the ordinary way back to a
    /// generic type after specializing it: the app jumps to the specialized
    /// type, which has no specialization tab, so this pane is left holding the
    /// type as it was before, and the sidebar then hands it the grown one.
    @Test("the specialization pane lists a specialization added to the type it shows")
    func specializationPaneListsAnAddedSpecialization() async throws {
        let environment = ViewModelTestEnvironment()
        let specializedWithInt = Fixtures.runtimeObject(
            name: "Box.Int",
            displayName: "Box<Int>",
            kind: .swift(.type(.struct)),
            properties: [.isSpecialized]
        )
        let specializedWithString = Fixtures.runtimeObject(
            name: "Box.String",
            displayName: "Box<String>",
            kind: .swift(.type(.struct)),
            properties: [.isSpecialized]
        )
        let box = Fixtures.runtimeObject(
            name: "Box",
            kind: .swift(.type(.struct)),
            children: [specializedWithInt],
            properties: [.isGeneric]
        )
        let viewModel = environment.make {
            InspectorSwiftSpecializationViewModel(
                runtimeObject: box,
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
        _ = try await nextValue(from: output.specializedChildren)

        viewModel.update(for: box.withAppendedChild(specializedWithString))

        let rows = try await nextValue(from: output.specializedChildren, timeout: 2) { $0.count == 2 }
        #expect(rows.map(\.runtimeObject.displayName) == ["Box<Int>", "Box<String>"])
    }
}
