//
//  CDSemanticString+ThemeProfile.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/8.
//

import AppKit
import RuntimeViewerCore

extension CDSemanticString {
    func attributedString(for provider: ThemeProfile) -> NSAttributedString {
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
