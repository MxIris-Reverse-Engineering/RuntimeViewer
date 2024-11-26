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

class InspectorNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        view.canDrawSubviewsIntoLayer = true
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
