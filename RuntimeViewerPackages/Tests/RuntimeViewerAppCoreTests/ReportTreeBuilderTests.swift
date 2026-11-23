import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore

/// What a rebuild of the Report tree builds: only what changed. The page rebuilt and reconfigured
/// the whole tree whenever any input moved — a corpus build's progress, about sixty times a second,
/// redid a hundred history batches with every image under them (PR121.59). A finished batch or
/// corpus build is built once now, and one kind of work's update leaves the other kind alone.
@Suite("ReportTreeBuilder")
@MainActor
struct ReportTreeBuilderTests {
    @Test("a corpus build's progress rebuilds its own row and its category, nothing else")
    func progressRebuildsOnlyTheRunningBuild() {
        let builder = ReportTreeBuilder()
        let imagePath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        let finishedBuilds = (0 ..< 100).map { _ in
            FindCorpusFinishedBuild(imagePath: "/usr/lib/libobjc.A.dylib", outcome: .cancelled, finishedAt: Date())
        }
        _ = builder.indexingCategory(batches: [], history: (0 ..< 100).map { _ in Self.finishedBatch(imageCount: 50) }, isEnabled: true)
        _ = builder.corpusCategory(states: [imagePath: .building(.init(built: 0, total: 100))], followedImagePaths: [imagePath], finishedBuilds: finishedBuilds, restoredImages: [:], isUnsupportedByEngine: false, isEnabled: true)
        let builtNodeCountAfterFirstBuild = builder.builtNodeCount

        for builtCount in 1 ... 60 {
            _ = builder.corpusCategory(states: [imagePath: .building(.init(built: builtCount, total: 100))], followedImagePaths: [imagePath], finishedBuilds: finishedBuilds, restoredImages: [:], isUnsupportedByEngine: false, isEnabled: true)
        }

        #expect(builder.builtNodeCount - builtNodeCountAfterFirstBuild == 60 * 2)
    }

    @Test("an unchanged indexing history is not built again")
    func unchangedHistoryIsReused() {
        let builder = ReportTreeBuilder()
        let history = (0 ..< 100).map { _ in Self.finishedBatch(imageCount: 50) }
        _ = builder.indexingCategory(batches: [], history: history, isEnabled: true)
        let builtNodeCountAfterFirstBuild = builder.builtNodeCount

        let category = builder.indexingCategory(batches: [], history: history, isEnabled: true)

        #expect(builder.builtNodeCount - builtNodeCountAfterFirstBuild == 1)
        #expect(category?.children.count == 100)
    }

    @Test("a batch moving into the history keeps the cell ViewModels its rows had while it ran")
    func finishedBatchKeepsItsCellViewModels() throws {
        let builder = ReportTreeBuilder()
        var batch = Self.finishedBatch(imageCount: 2)
        batch.isFinished = false
        let running = try #require(builder.indexingCategory(batches: [batch], history: [], isEnabled: true)?.children.first)
        batch.isFinished = true

        let finished = try #require(builder.indexingCategory(batches: [], history: [batch], isEnabled: true)?.children.first)

        #expect(finished.cellViewModel === running.cellViewModel)
        #expect(zip(finished.children, running.children).allSatisfy { $0.cellViewModel === $1.cellViewModel })
        #expect(finished.cellViewModel.isInProgress == false)
    }

    @Test("a history entry replaced by another snapshot of the batch is built again on the same cell ViewModels")
    func replacedHistoryEntryKeepsItsCellViewModels() throws {
        let builder = ReportTreeBuilder()
        var archived = Self.finishedBatch(imageCount: 2)
        archived.isCancelled = true
        let archivedNode = try #require(builder.indexingCategory(batches: [], history: [archived], isEnabled: true)?.children.first)
        // Rebuilds in between drop the row's cell ViewModel from the live ones; the cached subtree
        // still holds it.
        _ = builder.indexingCategory(batches: [], history: [archived], isEnabled: true)
        var ended = archived
        ended.items[0].state = .failed(message: "image not found")

        let endedNode = try #require(builder.indexingCategory(batches: [], history: [ended], isEnabled: true)?.children.first)

        #expect(endedNode.cellViewModel === archivedNode.cellViewModel)
        #expect(endedNode.cellViewModel.appearance.status == .failed(message: "1 of 2 images failed to index"))
    }

    @Test("rebuilding one kind of work leaves the other kind's cell ViewModels in place")
    func rebuildingOneKindKeepsTheOther() throws {
        let builder = ReportTreeBuilder()
        let imagePath = "/usr/lib/libobjc.A.dylib"
        var batch = Self.finishedBatch(imageCount: 1)
        batch.isFinished = false
        let runningBatch = try #require(builder.indexingCategory(batches: [batch], history: [], isEnabled: true)?.children.first)
        _ = builder.corpusCategory(states: [imagePath: .pending], followedImagePaths: [imagePath], finishedBuilds: [], restoredImages: [:], isUnsupportedByEngine: false, isEnabled: true)

        let laterBatch = try #require(builder.indexingCategory(batches: [batch], history: [], isEnabled: true)?.children.first)

        #expect(laterBatch.cellViewModel === runningBatch.cellViewModel)
    }

    @Test("Imported Type Names lists one row per SDK platform, with its version, its progress and the cache's size")
    func reportListsImportedTypeNamesPerPlatform() throws {
        let builder = ReportTreeBuilder()
        let status = RuntimeTypeIndexStatus(
            platforms: [
                .init(platformName: "maccatalyst", sdkVersion: "27.2-27C5", phase: .ready, indexedModuleCount: 40),
                .init(platformName: "macosx", sdkVersion: "27.2-27C5", phase: .building(finishedBatchCount: 1, queuedBatchCount: 3), indexedModuleCount: 12),
            ],
            cacheByteCount: 5_000_000
        )

        let category = try #require(builder.importedTypeNamesCategory(status: status))

        #expect(category.identifier == .category(.importedTypeNames))
        #expect(category.cellViewModel.appearance.title == "Imported Type Names")
        #expect(category.cellViewModel.appearance.detail == ByteCountFormatter.string(fromByteCount: 5_000_000, countStyle: .file))
        #expect(category.cellViewModel.appearance.showsEjectButton == false)
        #expect(category.children.map(\.identifier) == [.typeIndexPlatform(platformName: "maccatalyst"), .typeIndexPlatform(platformName: "macosx")])
        let catalystRow = category.children[0].cellViewModel
        #expect(catalystRow.appearance.title == "Mac Catalyst 27.2")
        #expect(catalystRow.appearance.detail == "Ready, 40 modules")
        #expect(catalystRow.appearance.status == ReportRowStatus.none)
        #expect(catalystRow.isInProgress == false)
        let macRow = category.children[1].cellViewModel
        #expect(macRow.appearance.title == "macOS 27.2")
        #expect(macRow.appearance.detail == "Indexing… 1 of 3 batches")
        #expect(macRow.appearance.status == .running)
        #expect(macRow.isInProgress)
        #expect(macRow.isCancellable == false)
    }

    @Test("Imported Type Names says why a platform cannot be indexed, and is left out when the engine has no type index")
    func importedTypeNamesExplainsUnavailablePlatforms() throws {
        let builder = ReportTreeBuilder()
        let status = RuntimeTypeIndexStatus(
            platforms: [
                .init(platformName: "iphoneos", sdkVersion: nil, phase: .unavailable(.sdkNotInstalled), indexedModuleCount: 0),
                .init(platformName: "macosx", sdkVersion: nil, phase: .unavailable(.noDeveloperDirectory), indexedModuleCount: 0),
            ],
            cacheByteCount: 0
        )

        let category = try #require(builder.importedTypeNamesCategory(status: status))

        #expect(category.cellViewModel.appearance.detail == "")
        #expect(category.children.map(\.cellViewModel.appearance.title) == ["iOS", "macOS"])
        #expect(category.children.map(\.cellViewModel.appearance.detail) == [
            "No SDK for this platform",
            "No developer directory (install Xcode or the Command Line Tools)",
        ])
        #expect(builder.importedTypeNamesCategory(status: .empty) == nil)
    }

    private static func finishedBatch(imageCount: Int) -> RuntimeIndexingBatch {
        RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: "/Applications/Sample.app/Contents/MacOS/Sample",
            depth: 1,
            reason: .appLaunch,
            items: (0 ..< imageCount).map { imageIndex in
                RuntimeIndexingTaskItem(id: "/usr/lib/libSample\(imageIndex).dylib", resolvedPath: nil, state: .completed, hasPriorityBoost: false)
            },
            isCancelled: false,
            isFinished: true
        )
    }
}
