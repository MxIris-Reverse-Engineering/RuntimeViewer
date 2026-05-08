import AppKit
import RuntimeViewerUI

final class BackgroundIndexingToolbarItem: MainToolbarController.IconButtonToolbarItem {
    static let identifier = NSToolbarItem.Identifier("backgroundIndexing")

    init() {
        super.init(itemIdentifier: Self.identifier, icon: .squareStack3dDownRight)
        label = "Indexing"
        paletteLabel = "Background Indexing"
        toolTip = "Background indexing"
    }
}
