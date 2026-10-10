import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// A private Swift type's row: its `displayName`, which the engine prints without private
/// discriminators, and a `Private` tag after it whenever the object carries private declarations.
/// The names and discriminators are SwiftUICore's.
@Suite("SidebarPrivateDeclarationTag")
@MainActor
struct SidebarPrivateDeclarationTagTests {
    private static let swiftUICorePath = "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore"

    private static let enabledKey = RuntimePrivateDeclaration(name: "EnabledKey", discriminator: "_09CE35833F3876FE3A3A46977D61FC64")

    private let environment = ViewModelTestEnvironment()

    @Test("a private type's row shows its name followed by a Private tag")
    func privateTypeRowShowsNameAndTag() {
        let cellViewModel = makeCell(for: Self.object("SwiftUI.EnabledKey", privateDeclarations: [Self.enabledKey]))
        #expect(cellViewModel.appearance.title.string == "SwiftUI.EnabledKey")
        #expect(cellViewModel.appearance.tags == [.privateDeclaration(isClickable: true)])
    }

    @Test("a row whose object carries no private declaration has no tag")
    func publicTypeHasNoTag() {
        let cellViewModel = makeCell(for: Self.object("SwiftUI.View"))
        #expect(cellViewModel.appearance.title.string == "SwiftUI.View")
        #expect(cellViewModel.appearance.tags.isEmpty)
    }

    @Test("a private type nested in a public one tags its own row only")
    func nestedPrivateTypeTagsItsOwnRow() {
        let cellViewModel = makeCell(for: Self.object("SwiftUI.Parent", children: [Self.object("SwiftUI.Parent.EnabledKey", privateDeclarations: [Self.enabledKey])]))
        #expect(cellViewModel.appearance.tags.isEmpty)
        #expect(cellViewModel.children.map(\.appearance.tags) == [[.privateDeclaration(isClickable: true)]])
    }

    @Test("in Open Quickly the tag only shows, so a click on it opens the row")
    func openQuicklyTagIsNotClickable() {
        let cellViewModel = makeCell(for: Self.object("SwiftUI.EnabledKey", privateDeclarations: [Self.enabledKey]), forOpenQuickly: true)
        #expect(cellViewModel.appearance.tags == [.privateDeclaration(isClickable: false)])
    }

    // MARK: - Helpers

    private func makeCell(for runtimeObject: RuntimeObject, forOpenQuickly: Bool = false) -> SidebarRuntimeObjectCellViewModel {
        environment.make { SidebarRuntimeObjectCellViewModel(runtimeObject: runtimeObject, forOpenQuickly: forOpenQuickly) }
    }

    private static func object(_ displayName: String, privateDeclarations: [RuntimePrivateDeclaration] = [], children: [RuntimeObject] = []) -> RuntimeObject {
        RuntimeObject(
            name: displayName,
            displayName: displayName,
            kind: .swift(.type(.struct)),
            imagePath: swiftUICorePath,
            children: children,
            privateDeclarations: privateDeclarations
        )
    }
}
