#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentTextViewController: ViewController<ContentTextViewModel> {
    let textView = UITextView()
    
    let runtimeObjectClicked = PublishRelay<RuntimeObjectType>()
    
    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            textView
        }

        textView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        textView.do {
            $0.isSelectable = true
            $0.isEditable = false
            $0.linkTextAttributes = [:]
            $0.delegate = self
        }
    }

    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)
        let input = ContentTextViewModel.Input(runtimeObjectClicked: runtimeObjectClicked.asSignal())
        let output = viewModel.transform(input)

        output.attributedString.drive(textView.rx.attributedText).disposed(by: rx.disposeBag)
    }
}

extension ContentTextViewController: UITextViewDelegate {
    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        return UIAction { _ in
            print(textItem.content)
        }
    }

    @available(iOS 17.0, *)
    func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
        switch textItem.content {
        case let .link(url):
            let jumpToDefinitionAction = UIAction(title: "Jump to Definition") { [weak self] _ in
                guard let self = self else { return }
                if let scheme = url.scheme, let host = url.host {
                    var runtimeObject: RuntimeObjectType?
                    switch scheme {
                    case "class":
                        runtimeObject = .class(named: host)
                    case "protocol":
                        runtimeObject = .protocol(named: host)
                    default:
                        break
                    }
                    if let runtimeObject {
                        runtimeObjectClicked.accept(runtimeObject)
                    }
                }
            }
            return .init(menu: UIMenu(children: [jumpToDefinitionAction]))
        default:
            return nil
        }
    }
}

#endif
