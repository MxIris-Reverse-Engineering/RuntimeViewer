import Foundation

extension DocumentState {
    /// The image Editor › Generation Options for This Image… acts on (proposal
    /// `generation-options-image-overrides`): the one the focused editor pane's tab shows — the image
    /// its object is in, or the image of an image page — or, on an empty tab, the image the sidebar has
    /// open. `nil` when there is none.
    public var imagePathForGenerationOptions: String? {
        if let entry = editorArea.focusedPane.activeTab.currentEntry {
            return entry.object?.imagePath ?? entry.imagePath
        }
        return currentImageNode?.path
    }
}
