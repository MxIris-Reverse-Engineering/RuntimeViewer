//
//  InspectorPlaceholderViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/30.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class InspectorPlaceholderViewController: UXVisualEffectViewController<InspectorPlaceholderViewModel> {
    let placeholderLabel = Label("No Selection")
    
    override func viewDidLoad() {
        super.viewDidLoad()
        hierarchy {
            placeholderLabel
        }

        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        placeholderLabel.do {
            $0.font = .systemFont(ofSize: 18, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }
}
