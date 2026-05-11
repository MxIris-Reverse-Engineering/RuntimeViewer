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
    public private(set) var topLevelRows: [SpecializationRowViewModel] = []

    /// Re-emits the row array on every mutation so `outlineView.rx.nodes`
    /// can diff and pick up new child rows. `@Observed` would filter
    /// duplicate-reference array writes, which is what we *don't* want here
    /// — children of an existing row mutate without changing the top-level
    /// references.
    private let topLevelRowsRelay = BehaviorRelay<[SpecializationRowViewModel]>(value: [])

    /// Fires after a generic candidate's inner parameters have been installed
    /// onto a row, so the controller can call `expandItem(_:expandChildren:)`
    /// without juggling its own bookkeeping.
    private let expandRowRelay = PublishRelay<SpecializationRowViewModel>()

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
        public let requestTypePickerClicked: Signal<[String]>
    }

    public struct Output {
        public let request: Driver<RuntimeSpecializationRequest?>
        public let rows: Driver<[SpecializationRowViewModel]>
        public let loadState: Driver<LoadState>
        public let canSpecialize: Driver<Bool>
        public let runtimeObjectDisplayName: Driver<String>
        public let expandRow: Signal<SpecializationRowViewModel>
    }

    public func transform(_ input: Input) -> Output {
        input.requestTypePickerClicked.emitOnNext { [weak self] parameterPath in
            guard let self else { return }
            router.trigger(.requestTypePicker(parameterPath: parameterPath))
        }
        .disposed(by: rx.disposeBag)

        input.specializeClicked.emitOnNext { [weak self] in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                await performSpecialize()
            }
        }
        .disposed(by: rx.disposeBag)

        input.cancelClicked.emit(to: router.rx.trigger(.cancel)).disposed(by: rx.disposeBag)

        return Output(
            request: $request.asDriver(onErrorJustReturn: nil),
            rows: topLevelRowsRelay.asDriver(),
            loadState: $loadState.asDriver(onErrorJustReturn: .idle),
            canSpecialize: $canSpecialize.asDriver(onErrorJustReturn: false),
            runtimeObjectDisplayName: Driver.just(runtimeObject.displayName),
            expandRow: expandRowRelay.asSignal()
        )
    }

    public init(runtimeObject: RuntimeObject, documentState: DocumentState, router: any Router<SpecializationRoute>) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)
        Task { [weak self] in
            guard let self else { return }
            await loadRequest()
        }
    }

    /// Apply the candidate the user picked in the popover. Generic candidates
    /// trigger a lazy `specializationRequest(forCandidate:in:)` fetch and
    /// then `expandRow` so the freshly populated inner rows are visible.
    public func applyArgumentChange(
        path: [String],
        candidate: RuntimeSpecializationRequest.Candidate
    ) {
        guard let row = locateRow(path: path, in: topLevelRows) else {
            #log(.error, "Cannot locate row for path \(path, privacy: .public)")
            return
        }
        row.applyCandidate(candidate)
        publishRowsAndRefresh()

        guard candidate.isGeneric else { return }

        row.setLoading()
        publishRowsAndRefresh()

        Task { [weak self] in
            guard let self else { return }
            do {
                let innerRequest = try await documentState.runtimeEngine
                    .specializationRequest(forCandidate: candidate.id, in: candidate.imagePath)
                await MainActor.run {
                    row.installInnerParameters(innerRequest.parameters)
                    self.publishRowsAndRefresh()
                    self.expandRowRelay.accept(row)
                }
            } catch {
                #log(.error, "Failed to fetch inner specialization request: \(error, privacy: .public)")
                await MainActor.run {
                    row.setLoadFailed(error.localizedDescription)
                    self.publishRowsAndRefresh()
                    self.errorRelay.accept(error)
                }
            }
        }
    }

    private func locateRow(
        path: [String],
        in rows: [SpecializationRowViewModel]
    ) -> SpecializationRowViewModel? {
        guard let head = path.first else { return nil }
        guard let match = rows.first(where: { $0.parameter.name == head }) else { return nil }
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
                SpecializationRowViewModel(parameterPath: [$0.name], parameter: $0)
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
            guard validation.isValid else {
                errorRelay.accept(PreflightFailedError(errors: validation.errors))
                return
            }
            let specialized = try await documentState.runtimeEngine.specialize(
                runtimeObject,
                with: selection
            )
            router.trigger(.specializeCompleted(specialized))
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
