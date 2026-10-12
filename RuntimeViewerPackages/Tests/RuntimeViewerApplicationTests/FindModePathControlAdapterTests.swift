import AppKit
import AppKitPlus
import Foundation
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// `FindModePathControlAdapter`: the Find page's mode path on AppKitPlus's `NSPopUpPathControl` —
/// proposal `draft-appkitplus-filter-and-path-controls`. The control is a real one, off screen. What
/// it shows is read from its path cell. A choice is made the way the control makes one — it selects
/// the chosen row's item, then tells its delegate — because a menu's tracking loop cannot run in a
/// test.
@Suite("FindModePathControlAdapter")
@MainActor
struct FindModePathControlAdapterTests {
    /// Every path the view model can send: each mode with each of its match styles.
    private static var allQueries: [FindQuery] {
        FindMode.allCases.flatMap { mode -> [FindQuery] in
            if mode.hasTextMatchStyles {
                return FindTextMatchStyle.allCases.map { FindQuery(mode: mode, textMatchStyle: $0) }
            } else if mode.hasMemberKinds {
                return FindMemberMatchStyle.allCases.map { FindQuery(mode: mode, memberMatchStyle: $0) }
            } else {
                return [FindQuery(mode: mode)]
            }
        }
    }

    private func makePathControl() -> (NSPopUpPathControl, FindModePathControlAdapter) {
        let pathControl = NSPopUpPathControl(frame: NSRect(x: 0, y: 0, width: 600, height: 17))
        pathControl.controlSize = .small
        let adapter = FindModePathControlAdapter(pathControl: pathControl)
        return (pathControl, adapter)
    }

    private func displayedComponentCells(of pathControl: NSPopUpPathControl) -> [NSPopUpPathComponentCell] {
        (pathControl.cell as? NSPopUpPathCell)?.pathComponentCells ?? []
    }

    @Test("shows the view model's path: Find, the mode, then the match style of a mode that has one")
    func showsTheViewModelsPath() {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        #expect(pathControl.selectsComponentsOneAtATime)
        for query in Self.allQueries {
            let path = FindModePathComponent.path(for: query)
            adapter.show(path)
            #expect(displayedComponentCells(of: pathControl).map(\.stringValue) == path.map(\.title), "\(query)")
        }
    }

    @Test("a component's menu lists the choices the view model offers there, with its separators")
    func menusListTheOfferedChoices() throws {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        for query in Self.allQueries {
            let path = FindModePathComponent.path(for: query)
            adapter.show(path)
            let componentCells = displayedComponentCells(of: pathControl)
            // The menu of every component after the first lists the children of the item before it,
            // and puts a separator wherever two neighbouring rows are in different groups.
            for index in path.indices.dropFirst() {
                let previousItem = try #require(componentCells[index - 1].representedObject as? FindModePathControlAdapter.Item)
                let menuItems = previousItem.children
                #expect(menuItems.map(\.choice) == path[index].menuChoices.map { Optional($0) }, "\(query)")
                let startsNewGroup = zip(menuItems.dropFirst(), menuItems).map { $0.groupIdentifier != $1.groupIdentifier }
                #expect(startsNewGroup == path[index].menuChoices.dropFirst().map(\.isPrecededBySeparator), "\(query)")
            }
        }
    }

    @Test("one path is always the same item, whatever was shown in between")
    func itemsKeepTheirIdentity() {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        let path = FindModePathComponent.path(for: FindQuery(mode: .descendantTypes, textMatchStyle: .startingWith))
        adapter.show(path)
        let shownItem = pathControl.selectedItem
        adapter.show(FindModePathComponent.path(for: FindQuery(mode: .members)))
        adapter.show(path)
        #expect(shownItem != nil)
        #expect(pathControl.selectedItem === shownItem)
    }

    @Test("a chosen row reaches the view model, and the path stays the one the view model sent")
    func choosingReportsTheChoiceAndKeepsThePath() throws {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        let path = FindModePathComponent.path(for: FindQuery())
        adapter.show(path)
        let shownItem = pathControl.selectedItem
        let membersItem = try #require(adapter.rootItem.children.first { $0.choice == .mode(.members) })

        var choices: [FindModePathChoice] = []
        let subscription = adapter.choiceSelected.emitOnNext { choices.append($0) }
        defer { subscription.dispose() }

        // What the control does with a chosen row: it selects the row's item, then tells its delegate.
        pathControl.selectedItem = membersItem
        adapter.popUpPathControl(pathControl, didSelect: membersItem)

        #expect(choices == [.mode(.members)])
        #expect(pathControl.selectedItem === shownItem)
        #expect(displayedComponentCells(of: pathControl).map(\.stringValue) == path.map(\.title))
    }

    @Test("Find opens no menu and cannot be chosen; the components after it can")
    func findIsATitle() {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        adapter.show(FindModePathComponent.path(for: FindQuery()))
        let opensMenu = displayedComponentCells(of: pathControl).map { componentCell in
            adapter.popUpPathControl(pathControl, shouldPopUpMenuFor: componentCell, item: componentCell.representedObject as? any NSPopUpPathItem)
        }
        #expect(opensMenu == [false, true, true])
        #expect(!adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: adapter.rootItem))
        for modeItem in adapter.rootItem.children {
            #expect(adapter.popUpPathControl(pathControl, shouldEnableSelectionOf: modeItem))
        }
    }

    @Test("a choice other than the default one is drawn in the accent colour")
    func accentsChoicesOtherThanTheDefault() {
        let (pathControl, adapter) = makePathControl()
        defer { withExtendedLifetime(adapter) {} }

        for query in Self.allQueries {
            let path = FindModePathComponent.path(for: query)
            adapter.show(path)
            let titleColors = displayedComponentCells(of: pathControl).enumerated().map { index, componentCell in
                adapter.popUpPathControl(pathControl, titleColorFor: componentCell, at: index)
            }
            #expect(titleColors == path.map { $0.isAccented ? NSColor.controlAccentColor : nil }, "\(query)")
        }
    }
}
