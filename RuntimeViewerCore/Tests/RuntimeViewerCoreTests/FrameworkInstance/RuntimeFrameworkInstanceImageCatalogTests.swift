#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore

/// Where a framework instance's two groups start in the sidebar and the jump
/// bars: at the folder holding all of a group's frameworks, as a file engine's
/// group starts at what it opened.
@Suite("Framework instance image catalog")
struct RuntimeFrameworkInstanceImageCatalogTests {
    private static let tablesPath = "/Volumes/RE/iWork/macOS/14.5/Frameworks/TSTables.framework/Versions/A/TSTables"
    private static let textPath = "/Volumes/RE/iWork/macOS/14.5/Frameworks/TSText.framework/Versions/A/TSText"

    @Test("Frameworks copied into one folder start at that folder")
    func frameworksInOneFolderStartThere() {
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: [Self.tablesPath, Self.textPath]) == "/Volumes/RE/iWork/macOS/14.5/Frameworks")
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: [Self.tablesPath]) == "/Volumes/RE/iWork/macOS/14.5/Frameworks")
    }

    @Test("A framework nested in another, or images in different folders, start at the folder they share")
    func imagesInDifferentFoldersStartAtTheFolderTheyShare() {
        let nestedPath = "/Volumes/RE/iWork/macOS/14.5/Frameworks/TSTables.framework/Versions/A/Frameworks/TSInner.framework/Versions/A/TSInner"
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: [Self.tablesPath, nestedPath]) == "/Volumes/RE/iWork/macOS/14.5/Frameworks")
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: [Self.tablesPath, "/Volumes/RE/Keynote/libKN.dylib"]) == "/Volumes/RE")
    }

    @Test("An empty group, or one sharing only /, starts at /")
    func emptyOrUnrelatedGroupsStartAtTheRoot() {
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: []) == nil)
        #expect(RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: [Self.tablesPath, "/usr/local/lib/libfoo.dylib"]) == nil)
    }

    @Test("The tree from that folder lists the framework bundles first and keeps every image's whole path")
    func treeListsTheBundlesFirstAndKeepsWholePaths() throws {
        let imagePaths = [Self.tablesPath, Self.textPath]
        let root = RuntimeImageNode.rootNode(
            for: imagePaths,
            name: RuntimeFrameworkInstanceImageCatalog.frameworksRootNodeName,
            startingAt: RuntimeFrameworkInstanceImageCatalog.commonFolder(holding: imagePaths)
        )

        #expect(root.children.map(\.name) == ["TSTables.framework", "TSText.framework"])
        let tablesBundle = try #require(root.children.first)
        let tablesBinary = try #require(tablesBundle.children.first?.children.first?.children.first)
        #expect(tablesBinary.name == "TSTables")
        #expect(tablesBinary.path == Self.tablesPath)
    }
}

#endif
