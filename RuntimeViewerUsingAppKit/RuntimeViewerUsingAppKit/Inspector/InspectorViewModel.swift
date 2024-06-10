//
//  InspectorViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures

class InspectorViewModel: ViewModel<InspectorRoutable> {
    struct Input {
        let stripProtocolConformanceChecked: Signal<Bool>
        let stripOverridesChecked: Signal<Bool>
        let stripDuplicatesChecked: Signal<Bool>
        let stripSynthesizedChecked: Signal<Bool>
        let stripCtorMethodChecked: Signal<Bool>
        let stripDtorMethodChecked: Signal<Bool>
        let addSymbolImageCommentsChecked: Signal<Bool>
        let addIvarOffsetCommentsChecked: Signal<Bool>
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
    }

    func transform(_ input: Input) -> Output {
        input.stripProtocolConformanceChecked.emitOnNext { AppDefaults[\.options].stripProtocolConformance = $0 }.disposed(by: rx.disposeBag)
        input.stripOverridesChecked.emitOnNext { AppDefaults[\.options].stripOverrides = $0 }.disposed(by: rx.disposeBag)
        input.stripDuplicatesChecked.emitOnNext { AppDefaults[\.options].stripDuplicates = $0 }.disposed(by: rx.disposeBag)
        input.stripSynthesizedChecked.emitOnNext { AppDefaults[\.options].stripSynthesized = $0 }.disposed(by: rx.disposeBag)
        input.stripCtorMethodChecked.emitOnNext { AppDefaults[\.options].stripCtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.stripDtorMethodChecked.emitOnNext { AppDefaults[\.options].stripDtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.addSymbolImageCommentsChecked.emitOnNext { AppDefaults[\.options].addSymbolImageComments = $0 }.disposed(by: rx.disposeBag)
        input.addIvarOffsetCommentsChecked.emitOnNext { AppDefaults[\.options].addIvarOffsetComments = $0 }.disposed(by: rx.disposeBag)
        
        return Output(
            stripProtocolConformanceChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripProtocolConformance),
            stripOverridesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripOverrides),
            stripDuplicatesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDuplicates),
            stripSynthesizedChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripSynthesized),
            stripCtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripCtorMethod),
            stripDtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDtorMethod),
            addSymbolImageCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addSymbolImageComments),
            addIvarOffsetCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addIvarOffsetComments)
        )
    }
}
