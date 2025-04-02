//
//  MainMenuItemView.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2025/3/31.
//

//import SwiftUI

//class MainMenuItemView: NSHostingView<MainMenuItemView.ContentView> {
//    struct ContentView: View {
//        let title: String
//
//        let icon: NSImage
//
//        var body: some View {
//            HStack {
//                Spacer()
//                Label {
//                    Text(title)
//                } icon: {
//                    Image(nsImage: icon)
//                }
//            }
//            .frame(maxWidth: .infinity)
//            .frame(minHeight: 30)
//        }
//    }
//
//    init(title: String, icon: NSImage) {
//        super.init(rootView: .init(title: title, icon: icon))
//        sizingOptions = .preferredContentSize
//    }
//
//    @available(*, unavailable)
//    @MainActor @preconcurrency dynamic required init?(coder aDecoder: NSCoder) {
//        fatalError("init(coder:) has not been implemented")
//    }
//
//    @available(*, unavailable)
//    @MainActor @preconcurrency required init(rootView: MainMenuItemView.ContentView) {
//        fatalError("init(rootView:) has not been implemented")
//    }
//}
