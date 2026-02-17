import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingConfigurationViewModel: ViewModel<MainRoute> {
    struct Input {
        let cancelClick: Signal<Void>
        let backClick: Signal<Void>
        let exportClick: Signal<Void>
        let objcFormatSelected: Signal<Int>
        let swiftFormatSelected: Signal<Int>
    }

    struct Output {
        let objcCount: Driver<Int>
        let swiftCount: Driver<Int>
        let hasObjC: Driver<Bool>
        let hasSwift: Driver<Bool>
        let imageName: Driver<String>
    }

    @Observed private(set) var objcCount: Int = 0
    @Observed private(set) var swiftCount: Int = 0
    @Observed private(set) var hasObjC: Bool = false
    @Observed private(set) var hasSwift: Bool = false

    let backRelay = PublishRelay<Void>()
    let exportClickedRelay = PublishRelay<Void>()

    private let exportingState: ExportingState

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func refreshFromState() {
        let objc = exportingState.selectedObjcObjects
        let swift = exportingState.selectedSwiftObjects
        objcCount = objc.count
        swiftCount = swift.count
        hasObjC = !objc.isEmpty
        hasSwift = !swift.isEmpty
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.backClick.emitOnNext { [weak self] in
            guard let self else { return }
            backRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.exportClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportClickedRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.objcFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.objcFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        input.swiftFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.swiftFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        return Output(
            objcCount: $objcCount.asDriver(),
            swiftCount: $swiftCount.asDriver(),
            hasObjC: $hasObjC.asDriver(),
            hasSwift: $hasSwift.asDriver(),
            imageName: .just(exportingState.imageName)
        )
    }
}
