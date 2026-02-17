import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingSelectionViewModel: ViewModel<MainRoute> {
    struct Input {
        let cancelClick: Signal<Void>
        let nextClick: Signal<Void>
        let toggleObject: Signal<RuntimeObject>
        let toggleAllObjC: Signal<Bool>
        let toggleAllSwift: Signal<Bool>
    }

    struct Output {
        let objcObjects: Driver<[RuntimeObject]>
        let swiftObjects: Driver<[RuntimeObject]>
        let selectedObjects: Driver<Set<RuntimeObject>>
        let summaryText: Driver<String>
        let isNextEnabled: Driver<Bool>
        let isLoading: Driver<Bool>
    }

    @Observed private(set) var objcObjects: [RuntimeObject] = []
    @Observed private(set) var swiftObjects: [RuntimeObject] = []
    @Observed private(set) var selectedObjects: Set<RuntimeObject> = []
    @Observed private(set) var isLoading: Bool = true

    let nextRelay = PublishRelay<Void>()

    private let exportingState: ExportingState

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        loadObjects()
    }

    private func loadObjects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let objects = try await documentState.runtimeEngine.objects(in: exportingState.imagePath)
                let objc = objects.filter { if case .swift = $0.kind { return false } else { return true } }
                let swift = objects.filter { if case .swift = $0.kind { return true } else { return false } }
                self.objcObjects = objc
                self.swiftObjects = swift
                self.selectedObjects = Set(objects)
                self.exportingState.allObjects = objects
                self.isLoading = false
            } catch {
                errorRelay.accept(error)
            }
        }
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.nextClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportingState.selectedObjects = selectedObjects
            nextRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.toggleObject.emitOnNext { [weak self] object in
            guard let self else { return }
            if selectedObjects.contains(object) {
                selectedObjects.remove(object)
            } else {
                selectedObjects.insert(object)
            }
        }
        .disposed(by: rx.disposeBag)

        input.toggleAllObjC.emitOnNext { [weak self] selected in
            guard let self else { return }
            if selected {
                selectedObjects.formUnion(objcObjects)
            } else {
                selectedObjects.subtract(objcObjects)
            }
        }
        .disposed(by: rx.disposeBag)

        input.toggleAllSwift.emitOnNext { [weak self] selected in
            guard let self else { return }
            if selected {
                selectedObjects.formUnion(swiftObjects)
            } else {
                selectedObjects.subtract(swiftObjects)
            }
        }
        .disposed(by: rx.disposeBag)

        let summaryText = $selectedObjects.asDriver().map { [weak self] selected -> String in
            guard let self else { return "" }
            let objcCount = objcObjects.filter { selected.contains($0) }.count
            let swiftCount = swiftObjects.filter { selected.contains($0) }.count
            return "\(objcCount + swiftCount) items selected (\(objcCount) ObjC, \(swiftCount) Swift)"
        }

        let isNextEnabled = $selectedObjects.asDriver().map { !$0.isEmpty }

        return Output(
            objcObjects: $objcObjects.asDriver(),
            swiftObjects: $swiftObjects.asDriver(),
            selectedObjects: $selectedObjects.asDriver(),
            summaryText: summaryText,
            isNextEnabled: isNextEnabled,
            isLoading: $isLoading.asDriver()
        )
    }
}
