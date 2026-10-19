import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerUI
import RuntimeViewerArchitectures
import MemberwiseInit

/// The Inspector's References tab: who calls the member at the content pane's insertion point, what
/// it calls, and which functions use the type on screen — one level of each, in the object's own
/// image, and Show in Find Navigator for the whole tree across every indexed image.
///
/// The member follows `DocumentState.cursorMember` while it is a member of the object on screen
/// with code of its own; off every member's line, the tab shows the type's references alone. Each
/// section is one state value built by its own pipeline, keyed on what it is about: moving the
/// insertion point to another member reloads the calls and leaves the type's references alone.
///
/// Nothing is asked while the tab is off screen: the Inspector keeps every tab of the object up to
/// date, and a scan for each object the user passes on the way would keep the engine's process
/// busy for nothing. A subject that changed while the tab was hidden is asked for when it shows.
/// Only the object's own image is read — the glance the tab is for — so a query is one image's
/// scan, which the Find navigator widens.
public final class InspectorReferencesViewModel: ViewModel<InspectorRuntimeObjectRoute> {
    public enum Section: CaseIterable, Sendable {
        case callers
        case callees
        case typeReferences

        public var title: String {
            switch self {
            case .callers: "Callers"
            case .callees: "Callees"
            case .typeReferences: "Type References"
            }
        }

        /// The Find navigator's mode for the section.
        var mode: FindMode {
            switch self {
            case .callers: .callHierarchy
            case .callees: .callees
            case .typeReferences: .typeReferences
            }
        }
    }

    /// One section's whole visible state as a single value: never "not loading" together with the
    /// previous subject's rows.
    public enum SectionState {
        /// The section does not apply: no member at the insertion point for the calls, a type
        /// whose references are not found for the references.
        case unavailable
        case loading
        /// The rows as listed — the functions with names, then the row gathering the unnamed ones
        /// and, while it is expanded, those — standing for `listedCount` of `totalCount` functions.
        case loaded(rows: [InspectorReferenceCellViewModel], listedCount: Int, totalCount: Int)
        case failed(String)
    }

    /// `SectionState` as it leaves the background fetch, with the subject it answers: the rows are
    /// built on the main scheduler, where their icons can be.
    private enum SectionResult {
        case unavailable
        case loading
        case loaded(FindCrossReferenceTree.LoadRequest, [FindCrossReferenceTree.LoadedRow])
        case failed(String)
    }

    /// The most rows a section lists; the Find navigator lists every one.
    static let rowLimit = 200

    /// The most references a section's query brings back.
    nonisolated static let referenceLimit = 2000

    @RxObserved
    private var runtimeObject: RuntimeObject

    /// Whether the tab is on screen; see the type's documentation.
    @RxObserved
    private var isVisible: Bool = false

    /// The member at the insertion point, when it is the shown object's and has code.
    @RxObserved
    public private(set) var member: RuntimeMemberReference?

    @RxObserved
    public private(set) var callersState: SectionState = .unavailable

    @RxObserved
    public private(set) var calleesState: SectionState = .unavailable

    @RxObserved
    public private(set) var typeReferencesState: SectionState = .unavailable

    /// Each section's subject whose unnamed functions are listed. A click on the row gathering them
    /// expands them for that subject alone, so the section's next subject starts collapsed.
    @RxObserved
    private var expandedUnnamedFunctions: [Section: FindCrossReferenceTree.LoadRequest] = [:]

    @MemberwiseInit(.public)
    public struct Input {
        public let rowClicked: Signal<InspectorReferenceCellViewModel>
        public let showInFindNavigatorClicked: Signal<Section>
        /// The tab appearing (`true`) and disappearing (`false`).
        public let isVisible: Driver<Bool>
    }

    public struct Output {
        /// The member the calls are about, or the type when there is none.
        public let subjectTitle: Driver<String>
        /// `In AppKit`: the image the sections read.
        public let scopeTitle: Driver<String>
        public let callers: Driver<SectionState>
        public let callees: Driver<SectionState>
        public let typeReferences: Driver<SectionState>
    }

    /// The lookup a click on a member's row started; the next click cancels it.
    private var memberDeclarationLookupTask: Task<Void, Never>?

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<InspectorRuntimeObjectRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        Observable.combineLatest($runtimeObject.asObservable(), documentState.$cursorMember.asObservable()) { object, cursorMember -> RuntimeMemberReference? in
            guard let cursorMember, cursorMember.object == object, FindCrossReferenceRoot.memberKindsWithCode.contains(cursorMember.kind) else { return nil }
            return cursorMember
        }
        .distinctUntilChanged()
        .bind(to: $member)
        .disposed(by: rx.disposeBag)

        let memberRequests = $member.asObservable().map { member in
            member.map { FindCrossReferenceTree.LoadRequest.calls(.member($0)) }
        }
        sectionStates(.callers, from: memberRequests)
            .bind(to: $callersState)
            .disposed(by: rx.disposeBag)
        sectionStates(.callees, from: memberRequests)
            .bind(to: $calleesState)
            .disposed(by: rx.disposeBag)
        sectionStates(.typeReferences, from: $runtimeObject.asObservable().map { object in
            FindCrossReferenceRoot.isReferenceableType(object) ? FindCrossReferenceTree.LoadRequest.typeReferences(object) : nil
        })
        .bind(to: $typeReferencesState)
        .disposed(by: rx.disposeBag)
    }

    /// Point the tab at another object. Re-entering the same object is ignored, so nothing is
    /// queried again and no placeholder flashes over rows already right.
    public func update(for runtimeObject: RuntimeObject) {
        guard self.runtimeObject != runtimeObject else { return }
        self.runtimeObject = runtimeObject
    }

    public func transform(_ input: Input) -> Output {
        input.rowClicked.emitOnNext { [weak self] cellViewModel in
            guard let self else { return }
            if let unnamedFunctionsGroup = cellViewModel.unnamedFunctionsGroup {
                toggle(unnamedFunctionsGroup)
            } else {
                open(cellViewModel.row)
            }
        }
        .disposed(by: rx.disposeBag)

        input.showInFindNavigatorClicked.emitOnNext { [weak self] section in
            guard let self, let request = findRequest(for: section) else { return }
            documentState.findSession.runCrossReferenceCommand(request)
        }
        .disposed(by: rx.disposeBag)

        input.isVisible.driveOnNext { [weak self] isVisible in
            guard let self else { return }
            self.isVisible = isVisible
        }
        .disposed(by: rx.disposeBag)

        let subjectTitle = Driver.combineLatest($member.asDriver(), $runtimeObject.asDriver()) { member, object in
            member.map(FindCrossReferenceNaming.title(of:)) ?? object.displayName
        }

        return Output(
            subjectTitle: subjectTitle,
            scopeTitle: $runtimeObject.asDriver().map { FindScope.images([$0.imagePath]).title },
            callers: $callersState.asDriver(),
            callees: $calleesState.asDriver(),
            typeReferences: $typeReferencesState.asDriver()
        )
    }

    // MARK: - Loading

    /// One section's pipeline: each subject is asked for once, the newest replacing the one in
    /// flight, behind the shared loading placeholder. Expanding or collapsing the unnamed functions
    /// lists the rows again without asking anything.
    private func sectionStates(_ section: Section, from subjects: Observable<FindCrossReferenceTree.LoadRequest?>) -> Observable<SectionState> {
        // A subject is asked for once the tab is on screen, and only once:
        // hiding and showing the tab again asks nothing more.
        let results = Observable.combineLatest(subjects.distinctUntilChanged(), $isVisible.asObservable())
            .filter { _, isVisible in isVisible }
            .map { request, _ in request }
            .distinctUntilChanged()
            .flatMapLatest { [weak self] request -> Observable<SectionResult> in
                guard let request else { return .just(.unavailable) }
                guard let self else { return .empty() }
                let engine = documentState.runtimeEngine
                let options = RuntimeCrossReferenceQueryOptions(
                    resultLimit: Self.referenceLimit,
                    maximumConcurrentScans: settings.search.maximumConcurrentCrossReferenceScans,
                    preparedIndexByteLimit: settings.search.preparedCrossReferenceByteLimit
                )
                return Observable<SectionResult>.async {
                    do {
                        return .loaded(request, try await Self.rows(for: request, in: section, options: options, engine: engine))
                    } catch {
                        return .failed(FindSession.crossReferenceFailureMessage(for: error))
                    }
                }
                .withLoadingPlaceholder(
                    .loading,
                    appearsAfter: LoadingPlaceholderTiming.appearsAfter,
                    staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
                )
            }
            .observeOnMainScheduler()
        let expandedRequest = $expandedUnnamedFunctions.asObservable()
            .map { $0[section] }
            .distinctUntilChanged()
        return Observable.combineLatest(results, expandedRequest) { result, expandedRequest -> SectionState in
            switch result {
            case .unavailable:
                return .unavailable
            case .loading:
                return .loading
            case .failed(let message):
                return .failed(message)
            case .loaded(let request, let loadedRows):
                return Self.sectionState(listing: loadedRows, in: section, for: request, showsUnnamedFunctions: expandedRequest == request)
            }
        }
    }

    /// A loaded section as listed: the functions with names, up to `rowLimit`, then the row the
    /// unnamed ones are gathered below — collapsed unless `showsUnnamedFunctions` — and while it is
    /// expanded those, up to `rowLimit` again. Every function counts toward the total, listed or not.
    static func sectionState(listing loadedRows: [FindCrossReferenceTree.LoadedRow], in section: Section, for request: FindCrossReferenceTree.LoadRequest, showsUnnamedFunctions: Bool) -> SectionState {
        let identifierPrefix = "inspector|\(section)|"
        let namedRows = loadedRows.filter { !$0.row.gathersUnnamedFunctions }.map(\.row)
        var cellViewModels = namedRows.prefix(rowLimit).map { row in
            InspectorReferenceCellViewModel(row: row, identifier: identifierPrefix + FindCrossReferenceTree.key(of: row.item))
        }
        var listedCount = cellViewModels.count
        var totalCount = namedRows.count
        if let gatheringRow = loadedRows.first(where: \.row.gathersUnnamedFunctions) {
            let unnamedRows = gatheringRow.children.map(\.row)
            let listedUnnamedRows = unnamedRows.prefix(rowLimit)
            listedCount += listedUnnamedRows.count
            totalCount += unnamedRows.count
            cellViewModels.append(InspectorReferenceCellViewModel(
                row: gatheringRow.row,
                identifier: identifierPrefix + FindCrossReferenceTree.key(of: gatheringRow.row.item),
                unnamedFunctionsGroup: InspectorReferenceCellViewModel.UnnamedFunctionsGroup(section: section, request: request, isExpanded: showsUnnamedFunctions)
            ))
            if showsUnnamedFunctions {
                cellViewModels += listedUnnamedRows.map { row in
                    InspectorReferenceCellViewModel(row: row, identifier: identifierPrefix + FindCrossReferenceTree.key(of: row.item))
                }
            }
        }
        return .loaded(rows: cellViewModels, listedCount: listedCount, totalCount: totalCount)
    }

    /// One level of the section, in the subject's own image, as the Find navigator groups it: one
    /// row per caller or callee, the runtime helper calls left out; for the type, its referencing
    /// functions, by title. In each, the functions nothing names are gathered last.
    private nonisolated static func rows(for request: FindCrossReferenceTree.LoadRequest, in section: Section, options: RuntimeCrossReferenceQueryOptions, engine: RuntimeEngine) async throws -> [FindCrossReferenceTree.LoadedRow] {
        switch (section, request) {
        case (.callers, .calls(.member(let member))):
            let result = try await engine.callers(of: .member(member), in: .image(path: member.object.imagePath), options: options)
            return FindCrossReferenceTree.rows(for: result.references, direction: .callers)
        case (.callees, .calls(let subject)):
            let result = try await engine.callees(of: subject, options: options)
            return FindCrossReferenceTree.rows(for: result.references, direction: .callees).filter { !$0.row.isRuntimeHelperCall }
        case (.typeReferences, .typeReferences(let object)):
            let result = try await engine.typeReferences(to: object, in: .image(path: object.imagePath), options: options)
            // The functions below each image, taken out of their images' rows and of the rows
            // gathering the unnamed ones, then ordered and gathered again as one list.
            let functionRows = FindCrossReferenceTree.rows(for: result.references, direction: .typeReferences)
                .flatMap(\.children)
                .flatMap { $0.row.gathersUnnamedFunctions ? $0.children : [$0] }
                .sorted { ($0.row.title as NSString).compare($1.row.title) == .orderedAscending }
            return FindCrossReferenceTree.gatheringUnnamedFunctions(functionRows, direction: .typeReferences)
        default:
            return []
        }
    }

    // MARK: - Actions

    /// A row goes where a Find navigator row goes: to the member its function implements, or to a
    /// type it references.
    private func open(_ row: FindCrossReferenceRow) {
        memberDeclarationLookupTask?.cancel()
        memberDeclarationLookupTask = nil
        switch row.item {
        case .function(let function):
            guard let member = function.member else { return }
            memberDeclarationLookupTask = FindCrossReferenceNavigation.open(member, declaration: nil, inNewTab: false, in: documentState, generationOptions: appDefaults.options)
        case .target(.type(_, let object?)):
            FindCrossReferenceNavigation.open(object, highlighting: nil, inNewTab: false, in: documentState)
        case .target, .image, .unnamedFunctions, .loading, .failure:
            break
        }
    }

    /// Expands the unnamed functions the row gathers, or collapses them.
    private func toggle(_ unnamedFunctionsGroup: InspectorReferenceCellViewModel.UnnamedFunctionsGroup) {
        expandedUnnamedFunctions[unnamedFunctionsGroup.section] = unnamedFunctionsGroup.isExpanded ? nil : unnamedFunctionsGroup.request
    }

    /// What Show in Find Navigator runs for a section.
    private func findRequest(for section: Section) -> FindCrossReferenceRequest? {
        switch section {
        case .callers, .callees:
            guard let member else { return nil }
            return FindCrossReferenceRequest(mode: section.mode, root: .member(member, declaration: nil))
        case .typeReferences:
            return FindCrossReferenceRequest.requests(for: runtimeObject).first
        }
    }
}

/// One row of a section of the Inspector's References tab: a caller, a callee, a function using
/// the type, or the row the unnamed ones are gathered below. Fixed once made — a section's new
/// answer, or the unnamed functions expanding, brings new rows — so its appearance is a plain value:
/// a Find navigator row of the same function, a size down (`FindResultCellStyle.Metrics.inspector`),
/// as the rest of the tab is set in the small system font.
public final class InspectorReferenceCellViewModel: NSObject, @unchecked Sendable {
    /// What the row gathering a section's unnamed functions toggles, and which way it points.
    struct UnnamedFunctionsGroup: Equatable {
        let section: InspectorReferencesViewModel.Section
        let request: FindCrossReferenceTree.LoadRequest
        let isExpanded: Bool
    }

    public let row: FindCrossReferenceRow

    public let appearance: FindResultCellAppearance

    let identifier: String

    /// Set on the row gathering the unnamed functions, which a click expands or collapses.
    let unnamedFunctionsGroup: UnnamedFunctionsGroup?

    init(row: FindCrossReferenceRow, identifier: String, unnamedFunctionsGroup: UnnamedFunctionsGroup? = nil) {
        self.row = row
        self.identifier = identifier
        self.unnamedFunctionsGroup = unnamedFunctionsGroup
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        var appearance = FindResultNode.makeAppearance(for: .crossReference(row), metrics: .inspector)
        // A list has no disclosure triangle to show the row expands; the icon shows it instead.
        if let unnamedFunctionsGroup {
            appearance.icon = FindResultCellStyle.disclosureIcon(isExpanded: unnamedFunctionsGroup.isExpanded)
        }
        self.appearance = appearance
        #else
        self.appearance = FindResultCellAppearance()
        #endif
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension InspectorReferenceCellViewModel: Differentiable {
    public var differenceIdentifier: String { identifier }

    public func isContentEqual(to source: InspectorReferenceCellViewModel) -> Bool {
        row == source.row && unnamedFunctionsGroup == source.unnamedFunctionsGroup
    }
}
#endif
