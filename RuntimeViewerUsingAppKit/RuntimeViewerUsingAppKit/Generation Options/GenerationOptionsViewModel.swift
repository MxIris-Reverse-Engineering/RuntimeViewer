import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import Dependencies

class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    struct Input {
        let stripProtocolConformanceChecked: Signal<Bool>
        let stripOverridesChecked: Signal<Bool>
        let stripDuplicatesChecked: Signal<Bool>
        let stripSynthesizedChecked: Signal<Bool>
        let stripCtorMethodChecked: Signal<Bool>
        let stripDtorMethodChecked: Signal<Bool>
        let addSymbolImageCommentsChecked: Signal<Bool>
        let addIvarOffsetCommentsChecked: Signal<Bool>
        let expandIvarRecordTypeMembersChecked: Signal<Bool>
        let printStrippedSymbolDescriptionChcecked: Signal<Bool>
        let emitOffsetCommentsChecked: Signal<Bool>
    }

    struct Output {
        let stripProtocolConformanceChecked: Driver<Bool>
        let stripOverridesChecked: Driver<Bool>
        let stripDuplicatesChecked: Driver<Bool>
        let stripSynthesizedChecked: Driver<Bool>
        let stripCtorMethodChecked: Driver<Bool>
        let stripDtorMethodChecked: Driver<Bool>
        let addSymbolImageCommentsChecked: Driver<Bool>
        let addIvarOffsetCommentsChecked: Driver<Bool>
        let expandIvarRecordTypeMembersChecked: Driver<Bool>
        let printStrippedSymbolDescriptionChcecked: Driver<Bool>
        let emitOffsetCommentsChecked: Driver<Bool>
    }

    @Dependency(\.appDefaults)
    var appDefaults

    func transform(_ input: Input) -> Output {
        input.stripProtocolConformanceChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripProtocolConformance = $0 }.disposed(by: rx.disposeBag)
        input.stripOverridesChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripOverrides = $0 }.disposed(by: rx.disposeBag)
        input.stripDuplicatesChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripDuplicates = $0 }.disposed(by: rx.disposeBag)
        input.stripSynthesizedChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripSynthesized = $0 }.disposed(by: rx.disposeBag)
        input.stripCtorMethodChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripCtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.stripDtorMethodChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.stripDtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.addSymbolImageCommentsChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.addSymbolImageComments = $0 }.disposed(by: rx.disposeBag)
        input.addIvarOffsetCommentsChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.addIvarOffsetComments = $0 }.disposed(by: rx.disposeBag)
        input.expandIvarRecordTypeMembersChecked.emitOnNext { AppDefaults.options.objcHeaderOptions.expandIvarRecordTypeMembers = $0 }.disposed(by: rx.disposeBag)
        input.printStrippedSymbolDescriptionChcecked.emitOnNext { AppDefaults.options.swiftInterfaceOptions.printStrippedSymbolicItem = $0 }.disposed(by: rx.disposeBag)
        input.emitOffsetCommentsChecked.emitOnNext { AppDefaults.options.swiftInterfaceOptions.emitOffsetComments = $0 }.disposed(by: rx.disposeBag)
        return Output(
            stripProtocolConformanceChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripProtocolConformance),
            stripOverridesChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripOverrides),
            stripDuplicatesChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripDuplicates),
            stripSynthesizedChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripSynthesized),
            stripCtorMethodChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripCtorMethod),
            stripDtorMethodChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripDtorMethod),
            addSymbolImageCommentsChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.addSymbolImageComments),
            addIvarOffsetCommentsChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.addIvarOffsetComments),
            expandIvarRecordTypeMembersChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.expandIvarRecordTypeMembers),
            printStrippedSymbolDescriptionChcecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.swiftInterfaceOptions.printStrippedSymbolicItem),
            emitOffsetCommentsChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.swiftInterfaceOptions.emitOffsetComments)
        )
    }
}
