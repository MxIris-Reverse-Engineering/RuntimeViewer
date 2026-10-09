import AppKit
import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// An image goes by one name wherever the navigators show it: its file name, extension included —
/// Find's scope and summary bar, Find's result rows and the Report navigator's rows alike. The Find
/// result rows used to drop the extension, so libobjc read "libobjc.A" there and "libobjc.A.dylib"
/// everywhere else (PR121.62).
@Suite("An image's display name")
@MainActor
struct ImageDisplayNameTests {
    private static let imagePath = "/usr/lib/libobjc.A.dylib"

    private static let object = RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: imagePath, children: [])

    @Test("a scope names its image by the file name, extension included")
    func scopeName() {
        #expect(FindScope.imageName(of: Self.imagePath) == "libobjc.A.dylib")
        #expect(FindScope.images([Self.imagePath]).name == "libobjc.A.dylib")
    }

    @Test("a Find result row for a type names the type's image the same way")
    func typeResultRow() {
        let title = FindResultNode.object(Self.object, matchCount: 1, children: []).appearance.title.string

        #expect(title.hasPrefix("NSObject"))
        #expect(title.hasSuffix(" libobjc.A.dylib"), "the row reads \(title)")
    }

    @Test("a Find relationship row names the type's image the same way")
    func relationshipResultRow() {
        let title = FindResultNode.relationship(RuntimeRelationshipNode(object: Self.object), path: "root").appearance.title.string

        #expect(title.hasSuffix(" libobjc.A.dylib"), "the row reads \(title)")
    }

    @Test("the Find summary bar names the image being printed the same way")
    func summaryBar() {
        let status = FindSession.corpusStatus(of: [Self.imagePath: .building(RuntimeInterfaceCorpusBuildProgress(built: 37, total: 100))])

        #expect(status == "1 image being made searchable · building libobjc.A.dylib 37%")
    }

    @Test("the Report navigator names an indexed image, a corpus being built and a corpus built the same way")
    func reportRows() {
        let itemRow = ReportCellViewModel(identifier: .indexingItem(batchID: RuntimeIndexingBatchID(), imagePath: Self.imagePath))
        ReportOutline.configure(itemRow, for: RuntimeIndexingTaskItem(id: Self.imagePath, resolvedPath: Self.imagePath, state: .completed, hasPriorityBoost: false))
        let buildRow = ReportCellViewModel(identifier: .corpusBuild(imagePath: Self.imagePath))
        ReportOutline.configure(buildRow, forCorpusOf: Self.imagePath, state: .pending, isFollowed: true)
        let finishedBuild = FindCorpusFinishedBuild(imagePath: Self.imagePath, outcome: .cancelled, finishedAt: nil)
        let finishedBuildRow = ReportCellViewModel(identifier: .finishedCorpusBuild(finishedBuild.id))
        ReportOutline.configure(finishedBuildRow, for: finishedBuild)

        #expect([itemRow, buildRow, finishedBuildRow].map(\.appearance.title) == ["libobjc.A.dylib", "libobjc.A.dylib", "libobjc.A.dylib"])
    }
}
