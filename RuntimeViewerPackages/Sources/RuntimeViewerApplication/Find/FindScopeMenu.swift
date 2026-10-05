import Foundation

/// A choice the scope button's menu offers.
public enum FindScopeMenuChoice: Hashable, Sendable {
    /// Every indexed image — Xcode's Workspace.
    case allIndexedImages
    /// The image the sidebar lists, as it is when the search runs.
    case currentImage
    /// The images the rows on screen come from — Xcode's Current Find Results.
    case currentFindResults
    /// The scope chooser sheet — Xcode's Custom Scopes….
    case customScopes
}

/// One item of the scope button's menu.
public struct FindScopeMenuItem: Hashable, Sendable {
    public let choice: FindScopeMenuChoice

    public let title: String

    public let isEnabled: Bool

    /// Whether it stands for the scope in use, the item the menu checks. A
    /// scope picked in the chooser has no item, so the menu checks none then,
    /// as Xcode's does.
    public let isChecked: Bool

    public let isPrecededBySeparator: Bool

    /// The menu in the order of Xcode's
    /// `-[IDEFindNavigatorQueryParametersController rebuildScopeChooserMenu]`:
    /// the scopes, then Current Find Results, then Custom Scopes…, each group
    /// set apart. The current image is offered only while the sidebar lists
    /// one, and Current Find Results only while the outline shows a row — the
    /// condition Xcode's `validateUserInterfaceItem:` puts on it.
    static func menu(for scope: FindScope, currentImagePath: String?, hasVisibleResults: Bool) -> [FindScopeMenuItem] {
        let currentImageTitle = currentImagePath.map { "\(FindScope.currentImage.name) (\(FindScope.imageName(of: $0)))" } ?? FindScope.currentImage.name
        return [
            FindScopeMenuItem(
                choice: .allIndexedImages,
                title: FindScope.allIndexedImages.name,
                isEnabled: true,
                isChecked: scope == .allIndexedImages,
                isPrecededBySeparator: false
            ),
            FindScopeMenuItem(
                choice: .currentImage,
                title: currentImageTitle,
                isEnabled: currentImagePath != nil,
                isChecked: scope == .currentImage,
                isPrecededBySeparator: false
            ),
            FindScopeMenuItem(
                choice: .currentFindResults,
                title: "Current Find Results",
                isEnabled: hasVisibleResults,
                isChecked: false,
                isPrecededBySeparator: true
            ),
            FindScopeMenuItem(
                choice: .customScopes,
                title: "Custom Scopes…",
                isEnabled: true,
                isChecked: false,
                isPrecededBySeparator: true
            ),
        ]
    }
}
