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
        let stripProtocolConformanceChecked: Observable<Bool>
        let stripOverridesChecked: Observable<Bool>
        let stripDuplicatesChecked: Observable<Bool>
        let stripSynthesizedChecked: Observable<Bool>
        let stripCtorMethodChecked: Observable<Bool>
        let stripDtorMethodChecked: Observable<Bool>
        let addSymbolImageCommentsChecked: Observable<Bool>
    }

    struct Output {
        let stripProtocolConformanceChecked: Driver<Bool>
        let stripOverridesChecked: Driver<Bool>
        let stripDuplicatesChecked: Driver<Bool>
        let stripSynthesizedChecked: Driver<Bool>
        let stripCtorMethodChecked: Driver<Bool>
        let stripDtorMethodChecked: Driver<Bool>
        let addSymbolImageCommentsChecked: Driver<Bool>
    }

    func transform(_ input: Input) -> Output {
        input.stripProtocolConformanceChecked.subscribeOnNext { AppDefaults[\.options].stripProtocolConformance = $0 }.disposed(by: rx.disposeBag)
        input.stripOverridesChecked.subscribeOnNext { AppDefaults[\.options].stripOverrides = $0 }.disposed(by: rx.disposeBag)
        input.stripDuplicatesChecked.subscribeOnNext { AppDefaults[\.options].stripDuplicates = $0 }.disposed(by: rx.disposeBag)
        input.stripSynthesizedChecked.subscribeOnNext { AppDefaults[\.options].stripSynthesized = $0 }.disposed(by: rx.disposeBag)
        input.stripCtorMethodChecked.subscribeOnNext { AppDefaults[\.options].stripCtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.stripDtorMethodChecked.subscribeOnNext { AppDefaults[\.options].stripDtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.addSymbolImageCommentsChecked.subscribeOnNext { AppDefaults[\.options].addSymbolImageComments = $0 }.disposed(by: rx.disposeBag)

        return Output(
            stripProtocolConformanceChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripProtocolConformance),
            stripOverridesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripOverrides),
            stripDuplicatesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDuplicates),
            stripSynthesizedChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripSynthesized),
            stripCtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripCtorMethod),
            stripDtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDtorMethod),
            addSymbolImageCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addSymbolImageComments)
        )
    }
}
