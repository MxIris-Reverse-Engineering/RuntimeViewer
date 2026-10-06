import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The batch export picker's image tree: what a query shows, and what a checkbox, Select All or
/// Deselect All does to the selection while a query is active.
@Suite("BatchExportingImageTree", .serialized)
@MainActor
struct BatchExportingImageTreeTests {
    private static let dyldSharedCacheImagePaths = [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData",
        "/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore",
        "/System/Library/PrivateFrameworks/UIFoundation.framework/Versions/A/UIFoundation",
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
        "/usr/lib/libobjc.A.dylib",
        "/usr/lib/swift/libswiftCore.dylib",
    ]

    private static let otherImagePaths = [
        "/Applications/Sample.app/Contents/MacOS/Sample",
        "/Applications/Sample.app/Contents/Frameworks/SampleKit.framework/Versions/A/SampleKit",
    ]

    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let coreDataPath = "/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData"
    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private static let uiFoundationPath = "/System/Library/PrivateFrameworks/UIFoundation.framework/Versions/A/UIFoundation"
    private static let uiKitCorePath = "/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore"

    private static func makeTree(otherImagePaths: [String]? = nil) -> BatchExportingImageTree {
        BatchExportingImageTree(imageRootNodes: [
            RuntimeImageNode.rootNode(for: dyldSharedCacheImagePaths, name: "Dyld Shared Cache"),
            RuntimeImageNode.rootNode(for: otherImagePaths ?? Self.otherImagePaths, name: "Others"),
        ])
    }

    // MARK: - Layout

    @Test("images are listed in the sidebar's order, under the engine's roots")
    func imagesFollowTheSidebarOrder() {
        let tree = Self.makeTree()

        #expect(tree.rootNodes.map(\.name) == ["Dyld Shared Cache", "Others"])
        #expect(tree.imageNodes.map(\.imagePath) == [
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/System/Library/Frameworks/CoreData.framework/Versions/A/CoreData",
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/PrivateFrameworks/UIFoundation.framework/Versions/A/UIFoundation",
            "/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore",
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/swift/libswiftCore.dylib",
            "/Applications/Sample.app/Contents/Frameworks/SampleKit.framework/Versions/A/SampleKit",
            "/Applications/Sample.app/Contents/MacOS/Sample",
        ])
    }

    @Test("an empty root is hidden instead of being offered as an image")
    func emptyRootIsNotAnImage() {
        let tree = Self.makeTree(otherImagePaths: [])

        #expect(tree.imageNodes.count == 7)
        #expect(tree.matchingRootNodes.map(\.name) == ["Dyld Shared Cache"])
    }

    // MARK: - Matching

    struct MatchingExpectation: Sendable, CustomTestStringConvertible {
        let query: BatchExportingImageQuery
        let expectedImageNames: [String]

        var testDescription: String {
            "\(query.matchMode) \(query.matchTarget) \(query.isCaseSensitive ? "case-sensitive" : "ignoring case") '\(query.text)'"
        }
    }

    @Test("a query matches images by name or full path", arguments: [
        MatchingExpectation(
            query: .init(text: "uikit"),
            expectedImageNames: ["UIKitCore"]
        ),
        MatchingExpectation(
            query: .init(text: "uikit", isCaseSensitive: true),
            expectedImageNames: []
        ),
        MatchingExpectation(
            query: .init(text: "UIKit", isCaseSensitive: true),
            expectedImageNames: ["UIKitCore"]
        ),
        MatchingExpectation(
            query: .init(text: " kit "),
            expectedImageNames: ["AppKit", "UIKitCore", "SampleKit"]
        ),
        MatchingExpectation(
            query: .init(text: "PrivateFrameworks"),
            expectedImageNames: []
        ),
        MatchingExpectation(
            query: .init(text: "PrivateFrameworks", matchTarget: .fullPath),
            expectedImageNames: ["SkyLight", "UIFoundation", "UIKitCore"]
        ),
        MatchingExpectation(
            query: .init(text: "^UI", matchMode: .regularExpression),
            expectedImageNames: ["UIFoundation", "UIKitCore"]
        ),
        MatchingExpectation(
            query: .init(text: "^ui", matchMode: .regularExpression),
            expectedImageNames: ["UIFoundation", "UIKitCore"]
        ),
        MatchingExpectation(
            query: .init(text: "^ui", matchMode: .regularExpression, isCaseSensitive: true),
            expectedImageNames: []
        ),
        MatchingExpectation(
            query: .init(text: "Kit$", matchMode: .regularExpression),
            expectedImageNames: ["AppKit", "SampleKit"]
        ),
        MatchingExpectation(
            query: .init(text: "\\.dylib$", matchMode: .regularExpression),
            expectedImageNames: ["libobjc.A.dylib", "libswiftCore.dylib"]
        ),
        MatchingExpectation(
            query: .init(text: "^UI", matchMode: .regularExpression, matchTarget: .fullPath),
            expectedImageNames: []
        ),
        MatchingExpectation(
            query: .init(text: "PrivateFrameworks/UI", matchMode: .regularExpression, matchTarget: .fullPath),
            expectedImageNames: ["UIFoundation", "UIKitCore"]
        ),
    ])
    func queryMatchesImages(_ expectation: MatchingExpectation) async {
        let tree = Self.makeTree()

        let isInstalled = await tree.apply(expectation.query)

        #expect(isInstalled)
        #expect(imageNames(of: tree.matchingImagePaths) == expectation.expectedImageNames)
    }

    @Test("a blank query shows every image")
    func blankQueryShowsEveryImage() async {
        let tree = Self.makeTree()
        await tree.apply(.init(text: "uikit"))

        await tree.apply(.init(text: "   ", matchMode: .regularExpression))

        #expect(tree.matchingImagePaths.count == 9)
        #expect(tree.matchingRootNodes.map(\.name) == ["Dyld Shared Cache", "Others"])
    }

    @Test("an invalid regular expression matches nothing and says why")
    func invalidRegularExpressionMatchesNothing() async {
        let tree = Self.makeTree()

        await tree.apply(.init(text: "(", matchMode: .regularExpression))

        #expect(tree.invalidQueryReason != nil)
        #expect(tree.matchingImagePaths.isEmpty)
        #expect(tree.matchingRootNodes.isEmpty)
    }

    @Test("fixing an invalid regular expression clears the reason")
    func validRegularExpressionClearsTheReason() async {
        let tree = Self.makeTree()
        await tree.apply(.init(text: "(", matchMode: .regularExpression))

        await tree.apply(.init(text: "(UI)", matchMode: .regularExpression))

        #expect(tree.invalidQueryReason == nil)
        #expect(imageNames(of: tree.matchingImagePaths) == ["UIFoundation", "UIKitCore"])
    }

    @Test("a folder is shown only while it holds a matching image")
    func foldersShowOnlyWhileTheyHoldAMatch() async {
        let tree = Self.makeTree()

        await tree.apply(.init(text: "^UI", matchMode: .regularExpression))

        #expect(shownRows(of: tree) == [
            "Dyld Shared Cache",
            "  System",
            "    Library",
            "      PrivateFrameworks",
            "        UIFoundation.framework",
            "          Versions",
            "            A",
            "              UIFoundation",
            "        UIKitCore.framework",
            "          Versions",
            "            A",
            "              UIKitCore",
        ])
    }

    @Test("a superseded query leaves the tree to the newer one")
    func supersededQueryChangesNothing() async {
        let tree = Self.makeTree()
        let olderQuery = BatchExportingImageQuery(text: "^UI", matchMode: .regularExpression)
        let newerQuery = BatchExportingImageQuery(text: "Sample")

        // Both start in creation order on the main actor; the older one is still matching off
        // the main actor when the newer one starts.
        let olderApplication = Task { await tree.apply(olderQuery) }
        let newerApplication = Task { await tree.apply(newerQuery) }
        let isOlderInstalled = await olderApplication.value
        let isNewerInstalled = await newerApplication.value

        #expect(!isOlderInstalled)
        #expect(isNewerInstalled)
        #expect(tree.query == newerQuery)
        #expect(imageNames(of: tree.matchingImagePaths) == ["SampleKit", "Sample"])
    }

    // MARK: - Checkboxes

    @Test("a folder's checkbox counts only the images the query matches")
    func folderCheckboxCountsOnlyMatchingImages() async throws {
        let tree = Self.makeTree()
        tree.updateSelection([Self.appKitPath, Self.skyLightPath])

        await tree.apply(.init(text: "^UI", matchMode: .regularExpression))
        let privateFrameworksWhileSearching = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "PrivateFrameworks"], in: tree)
        #expect(privateFrameworksWhileSearching.selection == .init(state: .unselected, selectedImageCount: 0, matchingImageCount: 2))

        await tree.apply(.init())
        let privateFrameworks = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "PrivateFrameworks"], in: tree)
        let dyldSharedCache = try shownNode(at: ["Dyld Shared Cache"], in: tree)
        #expect(privateFrameworks.selection == .init(state: .partiallySelected, selectedImageCount: 1, matchingImageCount: 3))
        #expect(dyldSharedCache.selection == .init(state: .partiallySelected, selectedImageCount: 2, matchingImageCount: 7))
    }

    @Test("a folder whose every image is selected shows as selected")
    func fullySelectedFolderShowsSelected() throws {
        let tree = Self.makeTree()

        tree.updateSelection([Self.appKitPath, Self.coreDataPath])

        let frameworks = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "Frameworks"], in: tree)
        #expect(frameworks.selection == .init(state: .selected, selectedImageCount: 2, matchingImageCount: 2))
    }

    @Test("checking a folder during a search selects only its matching images")
    func checkingAFolderDuringASearchSelectsItsMatches() async throws {
        let tree = Self.makeTree()
        await tree.apply(.init(text: "^UI", matchMode: .regularExpression))
        let privateFrameworks = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "PrivateFrameworks"], in: tree)

        let selection = tree.selection(afterToggling: privateFrameworks, in: [])

        #expect(selection == [Self.uiFoundationPath, Self.uiKitCorePath])
    }

    @Test("unchecking a folder during a search keeps the images the search hides")
    func uncheckingAFolderDuringASearchKeepsHiddenImages() async throws {
        let tree = Self.makeTree()
        let initialSelection: Set<String> = [Self.uiFoundationPath, Self.uiKitCorePath, Self.skyLightPath]
        tree.updateSelection(initialSelection)
        await tree.apply(.init(text: "^UI", matchMode: .regularExpression))
        let privateFrameworks = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "PrivateFrameworks"], in: tree)
        #expect(privateFrameworks.selection.state == .selected)

        let selection = tree.selection(afterToggling: privateFrameworks, in: initialSelection)

        #expect(selection == [Self.skyLightPath])
    }

    @Test("checking a partially selected folder selects the rest of it")
    func checkingAPartiallySelectedFolderSelectsTheRest() throws {
        let tree = Self.makeTree()
        tree.updateSelection([Self.appKitPath])
        let frameworks = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "Frameworks"], in: tree)

        let selection = tree.selection(afterToggling: frameworks, in: [Self.appKitPath])

        #expect(selection == [Self.appKitPath, Self.coreDataPath])
    }

    @Test("checking an image toggles that image alone")
    func checkingAnImageTogglesIt() throws {
        let tree = Self.makeTree()
        let appKit = try shownNode(at: ["Dyld Shared Cache", "System", "Library", "Frameworks", "AppKit.framework", "Versions", "C", "AppKit"], in: tree)

        let selected = tree.selection(afterToggling: appKit, in: [Self.coreDataPath])
        let deselected = tree.selection(afterToggling: appKit, in: selected)

        #expect(selected == [Self.appKitPath, Self.coreDataPath])
        #expect(deselected == [Self.coreDataPath])
    }

    @Test("Select All and Deselect All act on the matching images only")
    func selectAllAndDeselectAllActOnMatchingImages() async {
        let tree = Self.makeTree()
        await tree.apply(.init(text: "^UI", matchMode: .regularExpression))

        let allSelected = tree.selection(afterSelectingAllMatchingImagesIn: [Self.skyLightPath])
        let allDeselected = tree.selection(afterDeselectingAllMatchingImagesIn: allSelected)

        #expect(allSelected == [Self.skyLightPath, Self.uiFoundationPath, Self.uiKitCorePath])
        #expect(allDeselected == [Self.skyLightPath])
    }

    // MARK: - Helpers

    private func imageNames(of imagePaths: [String]) -> [String] {
        imagePaths.map { ($0 as NSString).lastPathComponent }
    }

    /// The rows the outline shows when every folder is expanded, indented two spaces per level.
    private func shownRows(of tree: BatchExportingImageTree) -> [String] {
        var rows: [String] = []
        func appendRows(of node: BatchExportingImageTreeNode, depth: Int) {
            rows.append(String(repeating: "  ", count: depth) + node.name)
            for child in node.children {
                appendRows(of: child, depth: depth + 1)
            }
        }
        for rootNode in tree.matchingRootNodes {
            appendRows(of: rootNode, depth: 0)
        }
        return rows
    }

    private func shownNode(at names: [String], in tree: BatchExportingImageTree) throws -> BatchExportingImageTreeNode {
        var shownNodes = tree.matchingRootNodes
        var foundNode: BatchExportingImageTreeNode?
        for name in names {
            let node = try #require(shownNodes.first { $0.name == name }, "no shown row named \(name)")
            foundNode = node
            shownNodes = node.children
        }
        return try #require(foundNode)
    }
}
