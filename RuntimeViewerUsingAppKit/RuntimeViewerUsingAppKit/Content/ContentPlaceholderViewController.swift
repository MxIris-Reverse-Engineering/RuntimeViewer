//
//  ContentPlaceholderViewController.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

class ContentPlaceholderViewController: ViewController<ContentPlaceholderViewModel> {
    let placeholderLabel = Label("Select a runtime object")

    override func viewDidLoad() {
        super.viewDidLoad()
        hierarchy {
            placeholderLabel
        }

        placeholderLabel.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }

        placeholderLabel.do {
            $0.font = .systemFont(ofSize: 20, weight: .regular)
            $0.textColor = .secondaryLabelColor
        }
    }
}
