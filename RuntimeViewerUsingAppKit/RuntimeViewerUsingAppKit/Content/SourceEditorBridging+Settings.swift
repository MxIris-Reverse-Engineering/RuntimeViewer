import RuntimeViewerSettings

extension SourceEditorBridging {
    /// Hands every Settings › Editor display toggle over in one call.
    ///
    /// All seven go together because the callers cannot narrow it down: `SwiftNavigation.observe`
    /// reports that *something* under `settings.editor` changed without saying which. The bridge
    /// diffs them against what it last applied, so re-sending an unchanged set costs nothing.
    func applyDisplayOptions(from editorSettings: Settings.Editor) {
        applyDisplayOptions(
            showsLineNumbers: editorSettings.showsLineNumbers,
            showsFoldingRibbon: editorSettings.showsFoldingRibbon,
            showsStickyHeaders: editorSettings.showsStickyHeaders,
            showsMinimap: editorSettings.showsMinimap,
            showsScopeGuides: editorSettings.showsScopeGuides,
            showsInvisibles: editorSettings.showsInvisibles,
            showsMarkSeparators: editorSettings.showsMarkSeparators
        )
    }
}
