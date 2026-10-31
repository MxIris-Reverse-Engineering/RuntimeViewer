import AppKit
import RuntimeViewerApplication

/// `InterfaceCommentDecorations` in the shape the editor bridge takes: parallel arrays of boxed
/// ranges and raw values behind an `@objc` protocol, which is all that crosses the bundle boundary.
final class SourceEditorCommentDecorations: NSObject, SourceEditorBridgingCommentDecorations {
    let tagRanges: [NSValue]
    let tagStyles: [NSNumber]
    let runRanges: [NSValue]
    let runStyles: [NSNumber]
    let hiddenRanges: [NSValue]
    let collapsibleDisclosureRanges: [NSValue]
    let collapsibleFoldRanges: [NSValue]
    let collapsibleStartsCollapsed: [NSNumber]

    init(_ decorations: InterfaceCommentDecorations) {
        tagRanges = decorations.tags.map { NSValue(range: $0.range) }
        tagStyles = decorations.tags.map { NSNumber(value: Self.bridgedStyle(of: $0.style).rawValue) }
        runRanges = decorations.runs.map { NSValue(range: $0.range) }
        runStyles = decorations.runs.map { NSNumber(value: Self.bridgedStyle(of: $0.style).rawValue) }
        hiddenRanges = decorations.hiddenRanges.map { NSValue(range: $0) }
        collapsibleDisclosureRanges = decorations.collapsibles.map { NSValue(range: $0.disclosureRange) }
        collapsibleFoldRanges = decorations.collapsibles.map { NSValue(range: $0.foldRange) }
        collapsibleStartsCollapsed = decorations.collapsibles.map { NSNumber(value: $0.startsCollapsed) }
    }

    private static func bridgedStyle(of style: InterfaceCommentDecorations.TagStyle) -> SourceEditorBridgingCommentTagStyle {
        switch style {
        case .standard: .standard
        case .warning: .warning
        case .note: .note
        }
    }

    private static func bridgedStyle(of style: InterfaceCommentDecorations.RunStyle) -> SourceEditorBridgingCommentRunStyle {
        switch style {
        case .label: .label
        case .value: .value
        case .type: .type
        case .name: .name
        case .concealed: .concealed
        }
    }
}
