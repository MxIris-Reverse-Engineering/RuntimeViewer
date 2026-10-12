#if os(macOS)

import AppKit
import AppKitPlus

/// A filter bar item whose menu lists every case of `Choice`, with at most one of them on: choosing a case turns it on
/// and the others off, and choosing the case that is on turns it off again. The item shows `image` while no case is
/// on and `alternateImage` while one is — an accent-coloured symbol, say, whose colours the bar keeps from AppKitPlus
/// 0.10.1 on.
public final class ChoiceFilterControlBarItem<Choice: CaseIterable & CustomStringConvertible & Equatable>: NSFilterControlBarItem {
    /// The case that is on, or `nil` while none is. Setting it updates the menu and the image, and does not call
    /// `selectionChanged`.
    public var selectedChoice: Choice? {
        didSet {
            updateSelectionAppearance()
        }
    }

    /// Called with the new `selectedChoice` after the user chooses from the menu.
    public var selectionChanged: ((Choice?) -> Void)?

    private let unselectedImage: NSImage?

    private let selectedImage: NSImage?

    public init(image: NSImage?, alternateImage: NSImage?) {
        self.unselectedImage = image
        self.selectedImage = alternateImage
        super.init(image: image, menu: NSMenu())
        for (index, choice) in Choice.allCases.enumerated() {
            let menuItem = NSMenuItem(title: choice.description, action: #selector(menuItemChosen(_:)), keyEquivalent: "")
            menuItem.target = self
            menuItem.tag = index
            menu?.addItem(menuItem)
        }
        updateSelectionAppearance()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func menuItemChosen(_ sender: NSMenuItem) {
        let choice = Array(Choice.allCases)[sender.tag]
        selectedChoice = selectedChoice == choice ? nil : choice
        selectionChanged?(selectedChoice)
    }

    private func updateSelectionAppearance() {
        for (menuItem, choice) in zip(menu?.items ?? [], Choice.allCases) {
            menuItem.state = choice == selectedChoice ? .on : .off
        }
        image = selectedChoice == nil ? unselectedImage : selectedImage
    }
}

#endif
