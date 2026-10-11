import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// A private Swift type's row: its `displayName`, which the engine prints without private
/// discriminators, and a `Private` tag after it whenever the object carries private declarations;
/// a type declared in a function or closure body carries a `Local` tag before it. The names and
/// discriminators are SwiftUICore's and SwiftUI's.
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

    // MARK: - Local Types

    @Test("a type declared in a private method shows a Local tag, then the Private tag of the method")
    func localTypeOfAPrivateMethodShowsBothTags() {
        let cellViewModel = makeCell(for: Self.object(
            "IndexingWrappingGenerator #1 in closure #1 in AccessibilityRotorInfo.readEntryList(_:)",
            properties: [.isLocalType],
            privateDeclarations: [.init(name: "readEntryList", discriminator: "_030667BFE09FD674B7612731735E240E")]
        ))
        #expect(cellViewModel.appearance.tags == [.localType(isPositionNamed: false), .privateDeclaration(isClickable: true)])
    }

    @Test("a local type the binary names no function for says so in its tag")
    func positionNamedLocalTypeSaysSo() {
        let cellViewModel = makeCell(for: Self.object("TableDataSource.(Visitor in $1a2b3c)", properties: [.isLocalType, .isPositionNamedLocalType]))
        #expect(cellViewModel.appearance.tags == [.localType(isPositionNamed: true)])
        #expect(cellViewModel.appearance.tags.allSatisfy { !$0.isClickable })
    }

    @Test("a type nested in a local type carries no Local tag of its own")
    func typeNestedInALocalTypeHasNoLocalTag() {
        let cellViewModel = makeCell(for: Self.object(
            "Generator #1 in Holder.nested()",
            properties: [.isLocalType],
            children: [Self.object("Element in Generator #1 in Holder.nested()")]
        ))
        #expect(cellViewModel.appearance.tags == [.localType(isPositionNamed: false)])
        #expect(cellViewModel.children.map(\.appearance.tags) == [[]])
    }

    @Test("in Open Quickly the Local tag shows too")
    func openQuicklyShowsLocalTag() {
        let cellViewModel = makeCell(for: Self.object("Visitor #1 in TableDataSource.performDrop(to:)", properties: [.isLocalType]), forOpenQuickly: true)
        #expect(cellViewModel.appearance.tags == [.localType(isPositionNamed: false)])
    }

    // MARK: - Helpers

    private func makeCell(for runtimeObject: RuntimeObject, forOpenQuickly: Bool = false) -> SidebarRuntimeObjectCellViewModel {
        environment.make { SidebarRuntimeObjectCellViewModel(runtimeObject: runtimeObject, forOpenQuickly: forOpenQuickly) }
    }

    private static func object(_ displayName: String, properties: RuntimeObject.Properties = [], privateDeclarations: [RuntimePrivateDeclaration] = [], children: [RuntimeObject] = []) -> RuntimeObject {
        RuntimeObject(
            name: displayName,
            displayName: displayName,
            kind: .swift(.type(.struct)),
            imagePath: swiftUICorePath,
            children: children,
            properties: properties,
            privateDeclarations: privateDeclarations
        )
    }
}
