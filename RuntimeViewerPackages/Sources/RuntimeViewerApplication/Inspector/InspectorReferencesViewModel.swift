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
        /// The first `rows` of `totalCount`.
        case loaded(rows: [InspectorReferenceCellViewModel], totalCount: Int)
        case failed(String)
    }

    /// `SectionState` as it leaves the background fetch: the rows are built on the main
    /// scheduler, where their icons can be.
    private enum SectionResult {
        case unavailable
        case loading
        case loaded([FindCrossReferenceRow])
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
            open(cellViewModel.row)
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
    /// flight, behind the shared loading placeholder.
    private func sectionStates(_ section: Section, from subjects: Observable<FindCrossReferenceTree.LoadRequest?>) -> Observable<SectionState> {
        // A subject is asked for once the tab is on screen, and only once:
        // hiding and showing the tab again asks nothing more.
        Observable.combineLatest(subjects.distinctUntilChanged(), $isVisible.asObservable())
            .filter { _, isVisible in isVisible }
            .map { request, _ in request }
            .distinctUntilChanged()
            .flatMapLatest { [weak self] request -> Observable<SectionResult> in
                guard let request else { return .just(.unavailable) }
                guard let self else { return .empty() }
                let engine = documentState.runtimeEngine
                let maximumConcurrentScans = settings.search.maximumConcurrentCrossReferenceScans
                return Observable<SectionResult>.async {
                    do {
                        return .loaded(try await Self.rows(for: request, in: section, maximumConcurrentScans: maximumConcurrentScans, engine: engine))
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
            .map { result -> SectionState in
                switch result {
                case .unavailable:
                    return .unavailable
                case .loading:
                    return .loading
                case .failed(let message):
                    return .failed(message)
                case .loaded(let rows):
                    let cellViewModels = rows.prefix(Self.rowLimit).map { row in
                        InspectorReferenceCellViewModel(row: row, identifier: "inspector|\(section)|" + FindCrossReferenceTree.key(of: row.item))
                    }
                    return .loaded(rows: Array(cellViewModels), totalCount: rows.count)
                }
            }
    }

    /// One level of the section, in the subject's own image, as the Find navigator groups it: one
    /// row per caller or callee, the runtime helper calls left out; for the type, its referencing
    /// functions, by title.
    private nonisolated static func rows(for request: FindCrossReferenceTree.LoadRequest, in section: Section, maximumConcurrentScans: Int, engine: RuntimeEngine) async throws -> [FindCrossReferenceRow] {
        let options = RuntimeCrossReferenceQueryOptions(resultLimit: referenceLimit, maximumConcurrentScans: maximumConcurrentScans)
        switch (section, request) {
        case (.callers, .calls(.member(let member))):
            let result = try await engine.callers(of: .member(member), in: .image(path: member.object.imagePath), options: options)
            return FindCrossReferenceTree.rows(for: result.references, direction: .callers).map(\.row)
        case (.callees, .calls(let subject)):
            let result = try await engine.callees(of: subject, options: options)
            return FindCrossReferenceTree.rows(for: result.references, direction: .callees).map(\.row).filter { !$0.isRuntimeHelperCall }
        case (.typeReferences, .typeReferences(let object)):
            let result = try await engine.typeReferences(to: object, in: .image(path: object.imagePath), options: options)
            return FindCrossReferenceTree.rows(for: result.references, direction: .typeReferences)
                .flatMap { $0.children.map(\.row) }
                .sorted { ($0.title as NSString).compare($1.title) == .orderedAscending }
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
        case .target, .image, .loading, .failure:
            break
        }
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

/// One row of a section of the Inspector's References tab: a caller, a callee, or a function using
/// the type. Fixed once made — a section's new answer brings new rows — so its appearance is a plain
/// value, the one a Find navigator row of the same function has.
public final class InspectorReferenceCellViewModel: NSObject, @unchecked Sendable {
    public let row: FindCrossReferenceRow

    public let appearance: FindResultCellAppearance

    let identifier: String

    init(row: FindCrossReferenceRow, identifier: String) {
        self.row = row
        self.identifier = identifier
        self.appearance = FindResultNode.crossReference(row, identifier: identifier, children: []).appearance
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension InspectorReferenceCellViewModel: Differentiable {
    public var differenceIdentifier: String { identifier }

    public func isContentEqual(to source: InspectorReferenceCellViewModel) -> Bool {
        row == source.row
    }
}
#endif
