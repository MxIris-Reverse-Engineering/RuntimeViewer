#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentTextViewController: UIKitViewController<ContentTextViewModel> {
    let textView = UITextView()

    let runtimeObjectClicked = PublishRelay<RuntimeObject>()

    /// Each interface once its text is in the text view.
    private let interfaceDisplayedRelay = PublishRelay<ContentInterface.ID>()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            textView
        }

        textView.snp.makeConstraints { make in
            make.edges.equalTo(view.safeAreaLayoutGuide)
        }

        textView.do {
            $0.isSelectable = true
            #if !os(tvOS)
            $0.isEditable = false
            #endif
            $0.linkTextAttributes = [:]
            $0.delegate = self
            $0.textContainerInset = .init(top: 0, left: 15, bottom: 0, right: 15)
        }
    }

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)
        let input = ContentTextViewModel.Input(runtimeObjectClicked: runtimeObjectClicked.asSignal(), runtimeObjectOpenedInNewTab: .empty(), interfaceDisplayed: interfaceDisplayedRelay.asSignal())
        let output = viewModel.transform(input)

        // Themed here in the settings' theme, which the Theme settings page edits; reported displayed
        // once set, which ends the view model's loading for it.
        let renderer = ContentTextRenderer(interfaces: output.interface)
        renderer.renderedText.driveOnNext { [weak self] renderedText in
            guard let self else { return }
            textView.attributedText = renderedText.attributedString
            interfaceDisplayedRelay.accept(renderedText.interface.id)
        }
        .disposed(by: rx.disposeBag)
        // The theme's background too, as the macOS pane does: a dark preset on a light background
        // would be unreadable.
        renderer.theme.driveOnNext { [weak self] theme in
            guard let self else { return }
            textView.backgroundColor = theme.backgroundColor
        }
        .disposed(by: rx.disposeBag)
        output.selectedRuntimeObjectName.drive(navigationItem.rx.title).disposed(by: rx.disposeBag)
    }
}

extension ContentTextViewController: UITextViewDelegate {
//    #if !os(tvOS)
//    @available(iOS 17.0, *)
//    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
//        return UIAction { _ in
//            print(textItem.content)
//        }
//    }
//
//    @available(iOS 17.0, *)
//    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
//        switch textItem.content {
//        case .link(let url):
//            let jumpToDefinitionAction = UIAction(title: "Jump to Definition") { [weak self] _ in
//                guard let self = self else { return }
////                #warning("RuntimeObjectType is not used in this context, consider using RuntimeObject")
//                if let scheme = url.scheme, let host = url.host {
////                    var runtimeObject: RuntimeObjCRuntimeObject?
////                    switch scheme {
////                    case "class":
////                        runtimeObject = .class(named: host)
////                    case "protocol":
////                        runtimeObject = .protocol(named: host)
////                    default:
////                        break
////                    }
////                    if let runtimeObject {
////                        runtimeObjectClicked.accept(runtimeObject)
////                    }
//                }
//            }
//            return .init(menu: UIMenu(children: [jumpToDefinitionAction]))
//        default:
//            return nil
//        }
//    }
//    #endif
}

#endif
