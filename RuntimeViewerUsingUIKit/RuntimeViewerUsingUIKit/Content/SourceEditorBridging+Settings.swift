// See SourceEditorBridgeProvider.swift for when this compiles.
#if RUNTIME_VIEWER_SOURCE_EDITOR

import RuntimeViewerSettings
import RuntimeViewerSourceEditorBridge

extension SourceEditorBridging {
    /// Hands every Settings › Editor display toggle over in one call, as the macOS app does; the
    /// iOS bridge carries out the four the UIKit build has and ignores the rest. The bridge diffs
    /// them against what it last applied, so re-sending an unchanged set costs nothing.
    func applyDisplayOptions(from editorSettings: Settings.Editor) {
        applyDisplayOptions(
            showsLineNumbers: editorSettings.showsLineNumbers,
            showsFoldingRibbon: editorSettings.showsFoldingRibbon,
            showsStickyHeaders: editorSettings.showsStickyHeaders,
            showsMinimap: editorSettings.showsMinimap,
            showsScopeGuides: editorSettings.showsScopeGuides,
            showsInvisibles: editorSettings.showsInvisibles,
            showsMarkSeparators: editorSettings.showsMarkSeparators,
            showsInsertionPoint: editorSettings.showsInsertionPoint
        )
    }
}

#endif
