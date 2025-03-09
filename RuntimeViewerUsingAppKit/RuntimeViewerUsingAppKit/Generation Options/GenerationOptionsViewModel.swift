//
//  GenerationOptionsViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/7/13.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class GenerationOptionsViewModel<Route: Routable>: ViewModel<Route> {
    public struct Input {
        public let stripProtocolConformanceChecked: Signal<Bool>
        public let stripOverridesChecked: Signal<Bool>
        public let stripDuplicatesChecked: Signal<Bool>
        public let stripSynthesizedChecked: Signal<Bool>
        public let stripCtorMethodChecked: Signal<Bool>
        public let stripDtorMethodChecked: Signal<Bool>
        public let addSymbolImageCommentsChecked: Signal<Bool>
        public let addIvarOffsetCommentsChecked: Signal<Bool>
        public let expandIvarRecordTypeMembersChecked: Signal<Bool>
        public init(
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

    public struct Output {
        public let stripProtocolConformanceChecked: Driver<Bool>
        public let stripOverridesChecked: Driver<Bool>
        public let stripDuplicatesChecked: Driver<Bool>
        public let stripSynthesizedChecked: Driver<Bool>
        public let stripCtorMethodChecked: Driver<Bool>
        public let stripDtorMethodChecked: Driver<Bool>
        public let addSymbolImageCommentsChecked: Driver<Bool>
        public let addIvarOffsetCommentsChecked: Driver<Bool>
        public let expandIvarRecordTypeMembersChecked: Driver<Bool>
    }

    public func transform(_ input: Input) -> Output {
        input.stripProtocolConformanceChecked.emitOnNext { AppDefaults[\.options].stripProtocolConformance = $0 }.disposed(by: rx.disposeBag)
        input.stripOverridesChecked.emitOnNext { AppDefaults[\.options].stripOverrides = $0 }.disposed(by: rx.disposeBag)
        input.stripDuplicatesChecked.emitOnNext { AppDefaults[\.options].stripDuplicates = $0 }.disposed(by: rx.disposeBag)
        input.stripSynthesizedChecked.emitOnNext { AppDefaults[\.options].stripSynthesized = $0 }.disposed(by: rx.disposeBag)
        input.stripCtorMethodChecked.emitOnNext { AppDefaults[\.options].stripCtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.stripDtorMethodChecked.emitOnNext { AppDefaults[\.options].stripDtorMethod = $0 }.disposed(by: rx.disposeBag)
        input.addSymbolImageCommentsChecked.emitOnNext { AppDefaults[\.options].addSymbolImageComments = $0 }.disposed(by: rx.disposeBag)
        input.addIvarOffsetCommentsChecked.emitOnNext { AppDefaults[\.options].addIvarOffsetComments = $0 }.disposed(by: rx.disposeBag)
        input.expandIvarRecordTypeMembersChecked.emitOnNext { AppDefaults[\.options].expandIvarRecordTypeMembers = $0 }.disposed(by: rx.disposeBag)
        return Output(
            stripProtocolConformanceChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripProtocolConformance),
            stripOverridesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripOverrides),
            stripDuplicatesChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDuplicates),
            stripSynthesizedChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripSynthesized),
            stripCtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripCtorMethod),
            stripDtorMethodChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.stripDtorMethod),
            addSymbolImageCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addSymbolImageComments),
            addIvarOffsetCommentsChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.addIvarOffsetComments),
            expandIvarRecordTypeMembersChecked: AppDefaults[\.$options].asDriverOnErrorJustComplete().map(\.expandIvarRecordTypeMembers)
        )
    }
}
