//
//  InspectorViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class InspectorViewController: NSTabViewController {
    let visualEffectView = NSVisualEffectView()

    override func viewDidLoad() {
        super.viewDidLoad()

//        hierarchy {
//            visualEffectView.hierarchy {}
//        }
//
//        visualEffectView.snp.makeConstraints { make in
//            make.edges.equalToSuperview()
//        }
        
        tabStyle = .unspecified
    }
}

extension CheckboxButton {
    convenience init(title: String, titleFont: NSFont? = nil, titleColor: NSColor? = nil, titleSpacing: CGFloat = 5.0) {
        self.init()
        self.attributedTitle = NSAttributedString {
            AText(title)
                .font(titleFont ?? .systemFont(ofSize: 13))
                .foregroundColor(titleColor ?? .labelColor)
                .paragraphStyle(NSMutableParagraphStyle().then {
                    $0.firstLineHeadIndent = titleSpacing
                    $0.lineBreakMode = .byClipping
                })
        }
    }
}
