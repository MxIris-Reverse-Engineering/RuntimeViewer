//
//  ContentTextViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/7.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures

class ContentTextViewModel: ViewModel<ContentRoute> {
    
    @Observed
    var theme: ThemeProvider
    
    
    @Observed
    var runtimeObject: RuntimeObjectType
    
    @Observed
    var attributedString: NSAttributedString
    
    init(runtimeObject: RuntimeObjectType, appServices: AppServices, router: UnownedRouter<ContentRoute>) {
        self.runtimeObject = runtimeObject
        let theme = XcodeDarkTheme()
        switch runtimeObject {
        case .class(let named):
            if let cls = NSClassFromString(named) {
                let classModel = CDClassModel(with: cls)
                self.attributedString = classModel.semanticLines(with: appServices.options).attributedString(for: theme)
            } else {
                self.attributedString = NSAttributedString {
                    AText("\(named) class not found.")
                }
            }
        case .protocol(let named):
            if let proto = NSProtocolFromString(named) {
                let protocolModel = CDProtocolModel(with: proto)
                self.attributedString = protocolModel.semanticLines(with: appServices.options).attributedString(for: theme)
            } else {
                self.attributedString = NSAttributedString {
                    AText("\(named) protocol not found.")
                }
            }
        }
        self.theme = theme
        super.init(appServices: appServices, router: router)
    }
    
    struct Input {}
    struct Output {
        let attributedString: Driver<NSAttributedString>
        let theme: Driver<ThemeProvider>
    }
    
    func transform(_ input: Input) -> Output {
        return Output(
            attributedString: $attributedString.asDriver(),
            theme: $theme.asDriver()
        )
    }
}

class ContentTextViewController: ViewController<ContentTextViewModel> {
    let scrollView = ScrollView()
    
    let textView = STTextView()

    override func viewDidLoad() {
        super.viewDidLoad()

        hierarchy {
            scrollView
        }

        scrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        scrollView.do {
            $0.documentView = textView
            $0.hasVerticalScroller = true
        }
        
        textView.do {
            $0.isEditable = false
            $0.isSelectable = true
        }
    }
    
    override func setupBindings(for viewModel: ContentTextViewModel) {
        super.setupBindings(for: viewModel)
        
        let input = ContentTextViewModel.Input()
        let output = viewModel.transform(input)
        
        output.attributedString.drive(with: self, onNext: { target, attributedString in
            target.textView.setAttributedString(attributedString)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                target.textView.scroll(.zero)
            }
        })
        .disposed(by: rx.disposeBag)
        
        output.theme.drive(with: self, onNext: {
            $0.textView.backgroundColor = $1.backgroundColor
            $0.textView.selectionBackgroundColor = $1.selectionBackgroundColor
        })
        .disposed(by: rx.disposeBag)
    }
}

import RuntimeViewerCore
extension CDSemanticString {
    func attributedString(for provider: ThemeProvider) -> NSAttributedString {
        let attributedString = NSMutableAttributedString(string: "")
        enumerateTypes { string, type in
            let attributes: [NSAttributedString.Key: Any] = [
                .font: provider.font(for: type),
                .foregroundColor: provider.color(for: type),
            ]
            attributedString.append(NSAttributedString(string: string, attributes: attributes))
        }
        return attributedString
    }
}

@MainActor
protocol ThemeProvider {
    var selectionBackgroundColor: NSColor { get }
    var backgroundColor: NSColor { get }
    func font(for type: CDSemanticType) -> NSFont
    func color(for type: CDSemanticType) -> NSColor
}

struct XcodeDarkTheme: ThemeProvider {
    
    let selectionBackgroundColor: NSColor = #colorLiteral(red: 0.3904261589, green: 0.4343567491, blue: 0.5144847631, alpha: 1)
    
    let backgroundColor: NSColor = #colorLiteral(red: 0.1251632571, green: 0.1258862913, blue: 0.1465735137, alpha: 1)
    
    
    func font(for type: CDSemanticType) -> NSFont {
        switch type {
        case .keyword:
            return .monospacedSystemFont(ofSize: 12, weight: .semibold)
        default:
            return .monospacedSystemFont(ofSize: 12, weight: .regular)
        }
    }

    func color(for type: CDSemanticType) -> NSColor {
        switch type {
        case .comment:
            return #colorLiteral(red: 0.4976348877, green: 0.5490466952, blue: 0.6000126004, alpha: 1)
        case .keyword:
            return #colorLiteral(red: 0.9686241746, green: 0.2627249062, blue: 0.6156817079, alpha: 1)
        case .variable, .method:
            return #colorLiteral(red: 0.2426597476, green: 0.7430019975, blue: 0.8773110509, alpha: 1)
        case .recordName, .class, .protocol:
            return #colorLiteral(red: 0.853918612, green: 0.730949223, blue: 1, alpha: 1)
        case .numeric:
            return #colorLiteral(red: 1, green: 0.9160019755, blue: 0.5006220341, alpha: 1)
        default:
            return .labelColor
        }
    }
}
