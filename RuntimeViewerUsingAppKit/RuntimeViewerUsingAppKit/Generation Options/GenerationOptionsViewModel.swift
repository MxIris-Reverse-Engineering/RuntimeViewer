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
        init(
            stripProtocolConformanceChecked: Signal<Bool>,
            stripOverridesChecked: Signal<Bool>,
            stripDuplicatesChecked: Signal<Bool>,
            stripSynthesizedChecked: Signal<Bool>,
            stripCtorMethodChecked: Signal<Bool>,
            stripDtorMethodChecked: Signal<Bool>,
            addSymbolImageCommentsChecked: Signal<Bool>,
            addIvarOffsetCommentsChecked: Signal<Bool>,
            expandIvarRecordTypeMembersChecked: Signal<Bool>
        ) {
            self.stripProtocolConformanceChecked = stripProtocolConformanceChecked
            self.stripOverridesChecked = stripOverridesChecked
            self.stripDuplicatesChecked = stripDuplicatesChecked
            self.stripSynthesizedChecked = stripSynthesizedChecked
            self.stripCtorMethodChecked = stripCtorMethodChecked
            self.stripDtorMethodChecked = stripDtorMethodChecked
            self.addSymbolImageCommentsChecked = addSymbolImageCommentsChecked
            self.addIvarOffsetCommentsChecked = addIvarOffsetCommentsChecked
            self.expandIvarRecordTypeMembersChecked = expandIvarRecordTypeMembersChecked
        }
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
        return Output(
            stripProtocolConformanceChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripProtocolConformance),
            stripOverridesChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripOverrides),
            stripDuplicatesChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripDuplicates),
            stripSynthesizedChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripSynthesized),
            stripCtorMethodChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripCtorMethod),
            stripDtorMethodChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.stripDtorMethod),
            addSymbolImageCommentsChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.addSymbolImageComments),
            addIvarOffsetCommentsChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.addIvarOffsetComments),
            expandIvarRecordTypeMembersChecked: appDefaults.$options.asDriverOnErrorJustComplete().map(\.objcHeaderOptions.expandIvarRecordTypeMembers)
        )
    }
}
