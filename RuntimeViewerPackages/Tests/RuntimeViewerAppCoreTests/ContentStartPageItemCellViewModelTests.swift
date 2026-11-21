import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What a row of an empty editor pane's start page shows (proposal `editor-start-page`): the
/// item's name, and under it a path that starts with the engine, as Xcode's initial editor starts a
/// recent file's path with its SDK or project.
@Suite("Start page rows")
struct ContentStartPageItemCellViewModelTests {
    @Test("an object row shows its display name under the engine and its image")
    func objectRowShowsEngineAndImage() {
        let object = Fixtures.runtimeObject(name: "_TtC5Sample4View", displayName: "View", imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")

        let row = ContentStartPageItemCellViewModel(item: .object(object), engineName: "My Mac", engineID: "engine")

        #expect(row.appearance.title == "View")
        #expect(row.appearance.pathComponents == ["My Mac", "AppKit"])
        #expect(row.appearance.pathIcon == .runtimeEngine(engineID: "engine"))
    }

    @Test("an image inside a bundle is shown under the folder holding the bundle")
    func imageInsideBundleIsShownUnderTheBundlesFolder() {
        let row = ContentStartPageItemCellViewModel(item: .image(path: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"), engineName: "My Mac", engineID: "engine")

        #expect(row.appearance.title == "AppKit")
        #expect(row.appearance.pathComponents == ["My Mac", "Frameworks"])
    }

    @Test("an image in a bundle inside another bundle is shown under the folder holding the nearer one")
    func imageInNestedBundleIsShownUnderTheNearerBundlesFolder() {
        let imagePath = "/Applications/Xcode.app/Contents/SharedFrameworks/DVTKit.framework/Versions/A/DVTKit"

        #expect(ContentStartPageItemCellViewModel.containingFolderName(ofImageAt: imagePath) == "SharedFrameworks")
    }

    @Test("an image outside any bundle is shown under its own folder")
    func imageOutsideBundlesIsShownUnderItsOwnFolder() {
        #expect(ContentStartPageItemCellViewModel.containingFolderName(ofImageAt: "/usr/lib/libobjc.A.dylib") == "lib")
    }

    @Test("an image at the root has no folder")
    func imageAtTheRootHasNoFolder() {
        let row = ContentStartPageItemCellViewModel(item: .image(path: "/dyld"), engineName: "My Mac", engineID: "engine")

        #expect(row.appearance.pathComponents == ["My Mac"])
    }
}
