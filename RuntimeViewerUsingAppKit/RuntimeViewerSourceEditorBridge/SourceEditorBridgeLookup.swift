// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path:
// official builds after FetchSourceEditorScript.sh, on Apple silicon. Anywhere else the app shows
// interfaces in the built-in text view and links none of them. Shared by the macOS and the iOS
// bridge: it uses only types both builds of the frameworks declare.
#if arch(arm64) && canImport(SourceEditor)

import Foundation
internal import SourceEditor
internal import SourceModelSupport

/// The two translations both bridges make between the app's words and the framework's.
enum SourceEditorBridgeLookup {
    /// The SourceModel language a `languageIdentifier` of `setSource` names. Nil leaves the text
    /// uncoloured altogether, semantic runs included: without a language the data source has no
    /// `SourceModelLanguageService`, the only place the `SemanticNodeTypeAdjuster` goes.
    static func language(forIdentifier languageIdentifier: String) -> (any SourceEditorLanguage)? {
        switch languageIdentifier {
        case "swift": SourceModelEditorLanguage.swift
        case "objc": SourceModelEditorLanguage.objc
        // `xcode.lang.cpp`, whose specification (`C++.xclangspec`) SourceModel ships.
        case "cpp": SourceModelEditorLanguage.cpp
        default: nil
        }
    }

    /// Declaration and definition fold together — Xcode draws them alike, and this pane shows
    /// interfaces, where everything is a declaration anyway. `@unknown default` is required:
    /// the enum is resilient, and a case Xcode adds later must not stop the label.
    static func landmarkKind(for landmarkType: LandmarkType) -> SourceEditorBridgingLandmarkKind {
        switch landmarkType {
        case .mark: .mark
        case .file: .file
        case .actorDef: .actor
        case .classDecl, .classDef: .class
        case .extensionDecl, .extensionDef: .extension
        case .protocolDecl, .protocolDef: .protocol
        case .methodDecl, .methodDef: .method
        case .functionDecl, .functionDef: .function
        case .propertyDecl, .propertyDef: .property
        case .enumDef: .enum
        case .structDef: .struct
        case .unionDef: .union
        case .typeDef: .typeAlias
        case .include: .include
        case .define: .define
        case .macro: .macro
        case .blockDirective, .rule, .entity, .attribute, .anchorTarget, .anchorLink,
             .key, .style, .heading, .probe, .process, .thread:
            .other
        @unknown default: .other
        }
    }
}

#endif
