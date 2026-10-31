import AppKit

/// Prototype only, never for `next`: switches the comment tag style at run time, so the
/// candidates can be compared on real interfaces. Lives in Debug › Comment Tag Style.
@MainActor
final class CommentTagStylePrototype: NSObject {
    fileprivate static let shared = CommentTagStylePrototype()

    static let didChangeNotification = Notification.Name("RuntimeViewerCommentTagStylePrototypeDidChange")

    static var currentVariant: SourceEditorCommentTagAppearance.Variant {
        shared.variant
    }

    private var variant: SourceEditorCommentTagAppearance.Variant = .softTints

    private let appearanceChoices: [(title: String, appearance: NSAppearance?)] = [
        ("跟随系统", nil),
        ("浅色", NSAppearance(named: .aqua)),
        ("深色", NSAppearance(named: .darkAqua)),
    ]

    private var variantItems: [NSMenuItem] = []

    private var appearanceItems: [NSMenuItem] = []

    private override init() { super.init() }

    /// The submenu to add to the Debug menu.
    static func makeMenuItem() -> NSMenuItem {
        shared.makeMenuItem()
    }

    private func makeMenuItem() -> NSMenuItem {
        let menu = NSMenu(title: "注释标签样式（原型）")
        variantItems = SourceEditorCommentTagAppearance.Variant.allCases.enumerated().map { index, variant in
            let item = NSMenuItem(title: variant.title, action: #selector(selectVariant(_:)), keyEquivalent: "\(index + 1)")
            item.keyEquivalentModifierMask = [.control, .option]
            item.target = self
            item.tag = index
            item.state = variant == self.variant ? .on : .off
            return item
        }
        variantItems.forEach(menu.addItem)
        menu.addItem(.separator())
        appearanceItems = appearanceChoices.enumerated().map { index, choice in
            let item = NSMenuItem(title: choice.title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.tag = index
            item.state = index == 0 ? .on : .off
            return item
        }
        appearanceItems.forEach(menu.addItem)

        let menuItem = NSMenuItem(title: "注释标签样式（原型）", action: nil, keyEquivalent: "")
        menuItem.submenu = menu
        return menuItem
    }

    @objc private func selectVariant(_ sender: NSMenuItem) {
        variant = SourceEditorCommentTagAppearance.Variant.allCases[sender.tag]
        for item in variantItems {
            item.state = item.tag == sender.tag ? .on : .off
        }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        NSApp.appearance = appearanceChoices[sender.tag].appearance
        for item in appearanceItems {
            item.state = item.tag == sender.tag ? .on : .off
        }
    }
}
