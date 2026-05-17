#if os(macOS)

import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

@Loggable(.private)
public final class SpecializationViewModel: ViewModel<SpecializationRoute> {

    public enum LoadState: Equatable, Sendable {
        case idle
        case loading
        case loaded
        case unsupported(reason: String)
        case failed(message: String)
    }

    public let runtimeObject: RuntimeObject

    @Observed
    public private(set) var request: RuntimeSpecializationRequest?

    /// Source-of-truth row tree for the outline form. The wire-level
    /// `RuntimeSpecializationSelection` is derived at preflight / specialize
    /// time by walking each row's `argument`, so we never have to keep two
    /// states in sync.
    public private(set) var topLevelRows: [SpecializationCellViewModel] = []

    /// Re-emits the row array on every mutation so `outlineView.rx.nodes`
    /// can diff and pick up new child rows. `@Observed` would filter
    /// duplicate-reference array writes, which is what we *don't* want here
    /// — children of an existing row mutate without changing the top-level
    /// references.
    private let topLevelRowsRelay = BehaviorRelay<[SpecializationCellViewModel]>(value: [])

    /// Fires after a generic candidate's inner parameters have been installed
    /// onto a row, so the controller can call `expandItem(_:expandChildren:)`
    /// without juggling its own bookkeeping.
    private let expandRowRelay = PublishRelay<SpecializationCellViewModel>()

    /// Fires whenever a row's child list changes — `outlineView.rx.nodes`
    /// uses DifferenceKit which can not detect mutation of a reference-typed
    /// `SpecializationCellViewModel` instance (same instance lives in both
    /// the source and target snapshots, so `isContentEqual` always returns
    /// true). The VC subscribes and calls `reloadItem(_:reloadChildren:)`
    /// to force NSOutlineView to re-query `numberOfChildrenOfItem`.
    private let reloadRowRelay = PublishRelay<SpecializationCellViewModel>()

    /// Tracks the in-flight `loadRequest()` started in `init` so it can be
    /// cancelled if the sheet is dismissed before the engine returns. Without
    /// this the engine still mutates `interfaceDefinitionNameByObject` for a
    /// document the user has already walked away from.
    private var loadRequestTask: Task<Void, Never>?

    /// Tracks the in-flight `performSpecialize()` task. A new specialize click
    /// cancels the previous one (defensive — UI normally disables the button
    /// while running), and `cancel`/`deinit` cancel it so a slow upstream
    /// specialize doesn't outlive the sheet.
    private var specializeTask: Task<Void, Never>?

    @Observed
    public private(set) var loadState: LoadState = .idle

    @Observed
    public private(set) var canSpecialize: Bool = false

    public struct Input {
        public let specializeClicked: Signal<Void>
        public let cancelClicked: Signal<Void>
        /// Fires when the user taps the "Choose Type" button on a row; the
        /// payload is the row's `parameterPath`. The VM forwards the path
        /// onto the coordinator, which resolves the anchor back from the VC
        /// and presents the type-picker popover.
        public let requestTypePickerClicked: Signal<[ParameterPathSegment]>
    }

    public struct Output {
        public let request: Driver<RuntimeSpecializationRequest?>
        public let rows: Driver<[SpecializationCellViewModel]>
        public let loadState: Driver<LoadState>
        public let canSpecialize: Driver<Bool>
        public let runtimeObjectDisplayName: Driver<String>
        public let expandRow: Signal<SpecializationCellViewModel>
        public let reloadRow: Signal<SpecializationCellViewModel>
    }

    public func transform(_ input: Input) -> Output {
        input.requestTypePickerClicked.emitOnNext { [weak self] parameterPath in
            guard let self else { return }
            router.trigger(.requestTypePicker(parameterPath: parameterPath))
        }
        .disposed(by: rx.disposeBag)

        input.specializeClicked.emitOnNext { [weak self] in
            guard let self else { return }
            specializeTask?.cancel()
            specializeTask = Task { [weak self] in
                guard let self else { return }
                await performSpecialize()
            }
        }
        .disposed(by: rx.disposeBag)

        input.cancelClicked.emitOnNext { [weak self] in
            guard let self else { return }
            // Cancel in-flight work synchronously before triggering dismissal
            // so the engine's specialize / specializationRequest paths see
            // `Task.isCancelled` at their next checkCancellation boundary
            // instead of completing and writing into
            // `interfaceDefinitionNameByObject` for a sheet the user has
            // already dismissed.
            cancelInflightWork()
            router.trigger(.cancel)
        }
        .disposed(by: rx.disposeBag)

        return Output(
            request: $request.asDriver(onErrorJustReturn: nil),
            rows: topLevelRowsRelay.asDriver(),
            loadState: $loadState.asDriver(onErrorJustReturn: .idle),
            canSpecialize: $canSpecialize.asDriver(onErrorJustReturn: false),
            runtimeObjectDisplayName: Driver.just(runtimeObject.displayName),
            expandRow: expandRowRelay.asSignal(),
            reloadRow: reloadRowRelay.asSignal()
        )
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<SpecializationRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
        loadRequestTask = Task { [weak self] in
            guard let self else { return }
            await loadRequest()
        }
    }

    deinit {
        loadRequestTask?.cancel()
        specializeTask?.cancel()
        for row in topLevelRows {
            row.cancelInflightRecursively()
        }
    }

    /// Cancel every Task this VM holds onto plus every row's in-flight inner
    /// fetch. Called from the cancel route and from `deinit` so an outstanding
    /// engine call cannot continue mutating section caches after the sheet
    /// has closed.
    private func cancelInflightWork() {
        loadRequestTask?.cancel()
        specializeTask?.cancel()
        for row in topLevelRows {
            row.cancelInflightRecursively()
        }
    }

    /// Apply the candidate the user picked in the popover. Generic candidates
    /// trigger a lazy `specializationRequest(forCandidate:in:)` fetch and
    /// then `expandRow` so the freshly populated inner rows are visible.
    public func applyArgumentChange(
        path: [ParameterPathSegment],
        candidate: RuntimeSpecializationRequest.Candidate
    ) {
        guard let row = locateRow(path: path, in: topLevelRows) else {
            #log(.error, "Cannot locate row for path \(String(describing: path), privacy: .public)")
            return
        }

        // Coalesce the synchronous transitions (apply candidate, optionally
        // splice the loading placeholder) into a single publish/reload pair.
        // The previous implementation fired three publish + reload pairs back
        // to back for a generic pick, producing visible flicker.
        row.applyCandidate(candidate)
        if candidate.isGeneric {
            row.setLoading()
        }
        publishRowsAndRefresh()
        reloadRowRelay.accept(row)

        guard candidate.isGeneric else { return }
        expandRowRelay.accept(row)

        let fetchTask: Task<Void, Never> = Task { [weak self, weak row] in
            guard let self, let row else { return }
            do {
                let innerRequest = try await documentState.runtimeEngine
                    .specializationRequest(forCandidateID: candidate.id, in: candidate.imagePath)
                if Task.isCancelled { return }
                await MainActor.run {
                    // Belt-and-braces: a re-pick to a different candidate
                    // bumped `selectedCandidate.id`, in which case we ignore
                    // the late result instead of splicing the wrong inner
                    // parameters under the new candidate.
                    guard row.selectedCandidate?.id == candidate.id else { return }
                    row.installInnerParameters(innerRequest.parameters)
                    row.clearInflightInnerFetch()
                    self.publishRowsAndRefresh()
                    self.reloadRowRelay.accept(row)
                    self.expandRowRelay.accept(row)
                }
            } catch {
                if Task.isCancelled { return }
                #log(.error, "Failed to fetch inner specialization request: \(error, privacy: .public)")
                await MainActor.run {
                    guard row.selectedCandidate?.id == candidate.id else { return }
                    row.setLoadFailed(error.localizedDescription)
                    row.clearInflightInnerFetch()
                    self.publishRowsAndRefresh()
                    // `setLoadFailed` cleared `children`, but `outlineView.rx.nodes`
                    // can not detect mutation on a reference-typed row (same
                    // instance lives in both diff snapshots), so force the
                    // outline view to re-query `numberOfChildrenOfItem`. Without
                    // this the "Loading inner parameters…" placeholder stays
                    // visible after the fetch fails.
                    self.reloadRowRelay.accept(row)
                    self.errorRelay.accept(error)
                }
            }
        }
        row.attachInflightInnerFetch(fetchTask)
    }

    private func locateRow(
        path: [ParameterPathSegment],
        in rows: [SpecializationCellViewModel]
    ) -> SpecializationCellViewModel? {
        guard let head = path.first else { return nil }
        // Loading placeholders are leaf-only synthetic rows; they never
        // appear as a `path.first` from the controller, but switching on
        // intent here documents that we deliberately ignore them.
        guard case .parameter(let name) = head else { return nil }
        guard let match = rows.first(where: { $0.parameter.name == name }) else { return nil }
        if path.count == 1 { return match }
        return locateRow(path: Array(path.dropFirst()), in: match.children)
    }

    private func publishRowsAndRefresh() {
        topLevelRowsRelay.accept(topLevelRows)
        refreshCanSpecialize()
    }

    private func refreshCanSpecialize() {
        guard case .loaded = loadState else {
            canSpecialize = false
            return
        }
        canSpecialize = !topLevelRows.isEmpty && topLevelRows.allSatisfy { $0.argument != nil }
    }

    private func loadRequest() async {
        loadState = .loading
        do {
            let req = try await documentState.runtimeEngine.specializationRequest(for: runtimeObject)
            request = req
            topLevelRows = req.parameters.map {
                SpecializationCellViewModel(parameterPath: [.parameter($0.name)], parameter: $0)
            }
            loadState = .loaded
            publishRowsAndRefresh()
        } catch RuntimeEngine.EngineError.imageNotIndexed(let imagePath) {
            loadState = .failed(message: "Image is not indexed: \(imagePath)")
        } catch RuntimeEngine.EngineError.typeNotGeneric {
            loadState = .failed(message: "This type is not generic.")
        } catch RuntimeEngine.EngineError.unsupportedGenericParameter(let description) {
            loadState = .unsupported(reason: description)
        } catch {
            #log(.error, "Failed to build specialization request: \(error, privacy: .public)")
            loadState = .failed(message: error.localizedDescription)
        }
    }

    private func performSpecialize() async {
        var arguments: [String: RuntimeSpecializationSelection.Argument] = [:]
        for row in topLevelRows {
            guard let argument = row.argument else {
                #log(.error, "Row for parameter \(row.parameter.name, privacy: .public) has no argument; specialize aborted")
                return
            }
            arguments[row.parameter.name] = argument
        }
        let selection = RuntimeSpecializationSelection(arguments: arguments)
        do {
            let validation = try await documentState.runtimeEngine.runtimePreflight(
                for: runtimeObject,
                with: selection
            )
            try Task.checkCancellation()
            guard validation.isValid else {
                errorRelay.accept(PreflightFailedError(errors: validation.errors))
                return
            }
            let specialized = try await documentState.runtimeEngine.specialize(
                runtimeObject,
                with: selection
            )
            try Task.checkCancellation()
            router.trigger(.specializeCompleted(specialized))
        } catch is CancellationError {
            // Sheet was dismissed mid-flight; swallow silently — no UI to update.
        } catch {
            #log(.error, "specialize failed: \(error, privacy: .public)")
            errorRelay.accept(error)
        }
    }
}

private struct PreflightFailedError: LocalizedError {
    let errors: [RuntimeSpecializationValidation.Error]

    var errorDescription: String? {
        let bullets = errors.map { "• \($0.description)" }.joined(separator: "\n")
        return "Specialization is not valid:\n\(bullets)"
    }
}

#endif
