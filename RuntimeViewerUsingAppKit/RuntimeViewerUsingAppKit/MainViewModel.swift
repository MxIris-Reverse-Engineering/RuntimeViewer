//
//  MainViewModel.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/4.
//

import AppKit
import RuntimeViewerArchitectures

class MainViewModel: ViewModel<MainRoute> {
    struct Input {
        let sidebarBackClick: Signal<Void>
    }
    
    struct Output {
        
    }
    
    func transform(_ input: Input) -> Output {
        input.sidebarBackClick.emit(to: router.rx.trigger(.sidebarBack)).disposed(by: rx.disposeBag)
        return Output()
    }
}
