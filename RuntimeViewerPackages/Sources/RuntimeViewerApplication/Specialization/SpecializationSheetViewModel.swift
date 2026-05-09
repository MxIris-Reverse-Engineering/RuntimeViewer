#if os(macOS)

import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

@Loggable(.private)
public final class SpecializationSheetViewModel: ViewModel<SpecializationRoute> {

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

    /// Public sink for popover-driven argument changes. The Coordinator pipes
    /// the candidate-picker's `didSelect` signal here so the VM stays
    /// agnostic of the popover's lifecycle.
    public let parameterArgumentChangedRelay =
        PublishRelay<(parameterName: String, candidate: RuntimeSpecializationRequest.Candidate)>()

    /// Public sink for the per-row "Choose Type" button. The VC fires this
    /// with the parameter name; the VM forwards it to the Coordinator (the
    /// Coordinator resolves the anchor view back from the VC).
    public let requestTypePickerClickedRelay = PublishRelay<String>()

    public struct Input {
        public let specializeClicked: Signal<Void>
        public let cancelClicked: Signal<Void>

        public init(specializeClicked: Signal<Void>, cancelClicked: Signal<Void>) {
            self.specializeClicked = specializeClicked
            self.cancelClicked = cancelClicked
        }
    }

    public struct Output {
        public let request: Driver<RuntimeSpecializationRequest?>
        public let selection: Driver<RuntimeSpecializationSelection>
        public let loadState: Driver<LoadState>
        public let canSpecialize: Driver<Bool>
        public let runtimeObjectDisplayName: Driver<String>
    }

    public func transform(_ input: Input) -> Output {
        parameterArgumentChangedRelay
            .asSignal()
            .emitOnNext { [weak self] (parameterName, candidate) in
                guard let self else { return }
                var newSelection = selection
                newSelection.setCandidate(candidate, for: parameterName)
                selection = newSelection
                refreshCanSpecialize()
            }
            .disposed(by: rx.disposeBag)

        requestTypePickerClickedRelay
            .asSignal()
            .emitOnNext { [weak self] parameterName in
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

        input.cancelClicked.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.cancel)
        }
        .disposed(by: rx.disposeBag)

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
            await self?.loadRequest()
        }
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


#endif
