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

    @Observed
    public private(set) var selection: RuntimeSpecializationSelection = .init()

    @Observed
    public private(set) var loadState: LoadState = .idle

    @Observed
    public private(set) var canSpecialize: Bool = false

    public struct Input {
        public let specializeClicked: Signal<Void>
        public let cancelClicked: Signal<Void>
        /// Fires when the user taps the "Choose Type" button on a row;
        /// payload is the parameter name. The VM forwards it to the
        /// coordinator, which resolves the anchor back from the VC.
        public let requestTypePickerClicked: Signal<String>
    }

    public struct Output {
        public let request: Driver<RuntimeSpecializationRequest?>
        public let selection: Driver<RuntimeSpecializationSelection>
        public let loadState: Driver<LoadState>
        public let canSpecialize: Driver<Bool>
        public let runtimeObjectDisplayName: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        input.requestTypePickerClicked.emitOnNext { [weak self] parameterName in
            guard let self else { return }
            router.trigger(.requestTypePicker(parameterName: parameterName))
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
            selection: $selection.asDriver(onErrorJustReturn: .init()),
            loadState: $loadState.asDriver(onErrorJustReturn: .idle),
            canSpecialize: $canSpecialize.asDriver(onErrorJustReturn: false),
            runtimeObjectDisplayName: Driver.just(runtimeObject.displayName)
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

    /// Applies the candidate selected in the type-picker popover. The
    /// coordinator calls this when handling
    /// `SpecializationRoute.didSelectCandidate(...)`, so the VM stays
    /// agnostic of the popover's lifecycle.
    public func applyArgumentChange(
        parameterName: String,
        candidate: RuntimeSpecializationRequest.Candidate
    ) {
        var newSelection = selection
        newSelection.setArgument(.candidate(candidate), for: parameterName)
        selection = newSelection
        refreshCanSpecialize()
    }

    private func refreshCanSpecialize() {
        guard case .loaded = loadState, let request else {
            canSpecialize = false
            return
        }
        canSpecialize = request.parameters.allSatisfy { selection.hasArgument(for: $0.name) }
    }

    private func loadRequest() async {
        loadState = .loading
        do {
            let req = try await documentState.runtimeEngine.specializationRequest(for: runtimeObject)
            request = req
            loadState = .loaded
            refreshCanSpecialize()
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
