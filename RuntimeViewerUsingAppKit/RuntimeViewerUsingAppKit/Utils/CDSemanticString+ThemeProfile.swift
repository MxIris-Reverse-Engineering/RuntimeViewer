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
            var attributes: [NSAttributedString.Key: Any] = [
                .font: provider.font(for: type),
                .foregroundColor: provider.color(for: type),
            ]
            if type == .class || type == .protocol {
                attributes.updateValue(type == .class ? RuntimeObjectType.class(named: string) : RuntimeObjectType.protocol(named: string), forKey: .link)
            }
            attributedString.append(NSAttributedString(string: string, attributes: attributes))
        }
        return attributedString
    }
}
