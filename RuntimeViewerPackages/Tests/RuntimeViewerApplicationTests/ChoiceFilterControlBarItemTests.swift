import AppKit
import AppKitPlus
import Testing
import RuntimeViewerUI

/// `ChoiceFilterControlBarItem`: the filter bar item the sidebar's filter mode sits on — proposal
/// `draft-appkitplus-filter-and-path-controls`. A choice is made the way a menu makes one: the
/// chosen item's action is sent to its target, from the item, because a menu's tracking loop
/// cannot run in a test.
@Suite("ChoiceFilterControlBarItem")
@MainActor
struct ChoiceFilterControlBarItemTests {
    private enum Fruit: CaseIterable, CustomStringConvertible, Equatable {
        case apple
        case pear
        case plum

        var description: String {
            switch self {
            case .apple:
                "Apple"
            case .pear:
                "Pear"
            case .plum:
                "Plum"
            }
        }
    }

    private let image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: nil)

    private let alternateImage = NSImage(systemSymbolName: "line.3.horizontal.decrease.circle.fill", accessibilityDescription: nil)

    private func makeItem() -> ChoiceFilterControlBarItem<Fruit> {
        ChoiceFilterControlBarItem<Fruit>(image: image, alternateImage: alternateImage)
    }

    private func choose(_ fruit: Fruit, in item: ChoiceFilterControlBarItem<Fruit>) throws {
        let index = try #require(Fruit.allCases.firstIndex(of: fruit))
        let menuItem = try #require(item.menu?.item(at: index))
        let target = try #require(menuItem.target as? NSObject)
        let action = try #require(menuItem.action)
        _ = target.perform(action, with: menuItem)
    }

    private func menuItemStates(of item: ChoiceFilterControlBarItem<Fruit>) -> [NSControl.StateValue] {
        item.menu?.items.map(\.state) ?? []
    }

    @Test("its menu lists every case, none of them on, and it shows its image")
    func listsEveryCase() {
        let item = makeItem()

        #expect(item.menu?.items.map(\.title) == ["Apple", "Pear", "Plum"])
        #expect(menuItemStates(of: item) == [.off, .off, .off])
        #expect(item.selectedChoice == nil)
        #expect(item.image === image)
    }

    @Test("choosing a case turns it on and the others off, shows the alternate image and reports the case")
    func choosingACaseTurnsItOn() throws {
        let item = makeItem()
        var reportedChoices: [Fruit?] = []
        item.selectionChanged = { reportedChoices.append($0) }

        try choose(.pear, in: item)
        #expect(item.selectedChoice == .pear)
        #expect(menuItemStates(of: item) == [.off, .on, .off])
        #expect(item.image === alternateImage)

        try choose(.plum, in: item)
        #expect(item.selectedChoice == .plum)
        #expect(menuItemStates(of: item) == [.off, .off, .on])
        #expect(reportedChoices == [.pear, .plum])
    }

    @Test("choosing the case that is on turns it off, shows the image again and reports nil")
    func choosingTheCaseThatIsOnTurnsItOff() throws {
        let item = makeItem()
        var reportedChoices: [Fruit?] = []
        item.selectionChanged = { reportedChoices.append($0) }

        try choose(.apple, in: item)
        try choose(.apple, in: item)

        #expect(item.selectedChoice == nil)
        #expect(menuItemStates(of: item) == [.off, .off, .off])
        #expect(item.image === image)
        #expect(reportedChoices == [.apple, nil])
    }

    @Test("setting the selection shows it at once and reports nothing, as when it is restored at launch")
    func settingTheSelectionReportsNothing() {
        let item = makeItem()
        var reportedChoices: [Fruit?] = []
        item.selectionChanged = { reportedChoices.append($0) }

        item.selectedChoice = .plum
        #expect(menuItemStates(of: item) == [.off, .off, .on])
        #expect(item.image === alternateImage)

        item.selectedChoice = nil
        #expect(menuItemStates(of: item) == [.off, .off, .off])
        #expect(item.image === image)
        #expect(reportedChoices.isEmpty)
    }
}
