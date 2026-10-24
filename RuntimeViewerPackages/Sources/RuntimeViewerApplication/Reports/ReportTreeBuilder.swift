import Foundation
import RuntimeViewerCore

/// Builds the Report navigator's tree one kind of work at a time, and keeps what does not change.
///
/// The page used to rebuild the whole tree whenever any input moved, so a corpus build's progress —
/// sixty times a second — rebuilt and reconfigured a hundred indexing batches with every image
/// under them. Each kind is now rebuilt from its own inputs only, and finished work — a batch in the
/// indexing history, an ended corpus build — is a snapshot whose subtree is built once and reused
/// while the entry stays. A row that is rebuilt keeps its cell ViewModel, so a row on screen still
/// updates in place.
@MainActor
final class ReportTreeBuilder {
    /// The cell ViewModels of the rows the last rebuild of each kind made, by what they stand for.
    /// A reused finished subtree holds its own and is not in here.
    private var cellViewModelsByIdentifier: [ReportNodeIdentifier: ReportCellViewModel] = [:]

    /// The indexing history's subtrees by batch, with the snapshot each was built from, so an entry
    /// that changes is built again.
    private var historyBatchNodes: [RuntimeIndexingBatchID: (batch: RuntimeIndexingBatch, node: ReportNode)] = [:]

    /// Ended corpus builds' rows by entry. An entry never changes once recorded.
    private var finishedCorpusBuildNodes: [UUID: ReportNode] = [:]

    /// Ended cross-reference preparations' rows by entry, likewise.
    private var finishedCrossReferencePreparationNodes: [UUID: ReportNode] = [:]

    /// Nodes built since the builder was made — the regression seam for the reuse above, as
    /// `StatefulOutlineView.expansionAutosavePersistCount` is one for its coalescing.
    private(set) var builtNodeCount = 0

    /// The Background Indexing category, or `nil` when it has nothing to show: a "Turned off in
    /// Settings" row while the switch is off, the running batches newest first, then the history.
    func indexingCategory(batches: [RuntimeIndexingBatch], history: [RuntimeIndexingBatch], isEnabled: Bool) -> ReportNode? {
        var usedIdentifiers: Set<ReportNodeIdentifier> = []
        var children: [ReportNode] = []
        if !isEnabled {
            children.append(makeNode(.turnedOff(.backgroundIndexing), usedIdentifiers: &usedIdentifiers) {
                $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings")
            })
        }
        // The manager appends batches as they start, and history is newest first already.
        for batch in batches.reversed() {
            children.append(makeBatchNode(batch, usedIdentifiers: &usedIdentifiers))
        }
        var historyBatchIdentifiers: Set<RuntimeIndexingBatchID> = []
        for batch in history {
            historyBatchIdentifiers.insert(batch.id)
            let cachedEntry = historyBatchNodes[batch.id]
            if let cachedEntry, cachedEntry.batch == batch {
                children.append(cachedEntry.node)
            } else {
                // A replaced snapshot is built again on the cell ViewModels its rows already have:
                // a cell on screen stays bound to the one it was made with.
                let node = makeBatchNode(batch, reusingCellViewModelsOf: cachedEntry?.node, usedIdentifiers: &usedIdentifiers)
                historyBatchNodes[batch.id] = (batch, node)
                children.append(node)
            }
        }
        historyBatchNodes = historyBatchNodes.filter { historyBatchIdentifiers.contains($0.key) }

        var categoryNode: ReportNode?
        if !children.isEmpty {
            categoryNode = makeNode(.category(.backgroundIndexing), children: children, usedIdentifiers: &usedIdentifiers) {
                $0.update(icon: ReportOutline.indexingIcon, title: "Background Indexing")
            }
        }
        dropCellViewModels(of: .backgroundIndexing, except: usedIdentifiers)
        return categoryNode
    }

    /// The Searchable Interfaces category, or `nil` when it has nothing to show: a row saying the
    /// feature is turned off or unsupported, the corpora queued or being printed, the group of the
    /// corpora read from derived data, then the ended builds.
    func corpusCategory(
        states: [String: RuntimeInterfaceCorpusBuildState],
        followedImagePaths: Set<String>,
        finishedBuilds: [FindCorpusFinishedBuild],
        restoredImages: [String: RuntimeInterfaceCorpusRestoredImage],
        isUnsupportedByEngine: Bool,
        isEnabled: Bool
    ) -> ReportNode? {
        var usedIdentifiers: Set<ReportNodeIdentifier> = []
        var children: [ReportNode] = []
        if !isEnabled {
            children.append(makeNode(.turnedOff(.searchableInterfaces), usedIdentifiers: &usedIdentifiers) {
                $0.update(icon: ReportOutline.turnedOffIcon, title: "Turned off in Settings")
            })
        } else if isUnsupportedByEngine {
            children.append(makeNode(.unsupportedByEngine(.searchableInterfaces), usedIdentifiers: &usedIdentifiers) {
                ReportOutline.configureUnsupportedCorpusRow($0)
            })
        }
        // The image being printed first, then the waiting ones by name.
        let activeBuilds = states.filter(\.value.isActive).sorted { leftEntry, rightEntry in
            let leftIsBuilding = ReportOutline.isBuilding(leftEntry.value)
            let rightIsBuilding = ReportOutline.isBuilding(rightEntry.value)
            if leftIsBuilding != rightIsBuilding {
                return leftIsBuilding
            }
            return FindScope.imageName(of: leftEntry.key) < FindScope.imageName(of: rightEntry.key)
        }
        for (imagePath, state) in activeBuilds {
            children.append(makeNode(.corpusBuild(imagePath: imagePath), usedIdentifiers: &usedIdentifiers) {
                ReportOutline.configure($0, forCorpusOf: imagePath, state: state, isFollowed: followedImagePaths.contains(imagePath))
            })
        }
        // One row per image, by name, under a group of their own: they were read, not built.
        if !restoredImages.isEmpty {
            let restoredRows = restoredImages
                .sorted { FindScope.imageName(of: $0.key) < FindScope.imageName(of: $1.key) }
                .map { imagePath, restoredImage in
                    makeNode(.restoredCorpus(imagePath: imagePath), usedIdentifiers: &usedIdentifiers) {
                        ReportOutline.configure($0, forCorpusOf: imagePath, restoredAs: restoredImage)
                    }
                }
            children.append(makeNode(.restoredCorpora, children: restoredRows, usedIdentifiers: &usedIdentifiers) {
                ReportOutline.configureRestoredCorporaRow($0, imageCount: restoredRows.count)
            })
        }
        var finishedBuildIdentifiers: Set<UUID> = []
        for finishedBuild in finishedBuilds {
            finishedBuildIdentifiers.insert(finishedBuild.id)
            if let cachedNode = finishedCorpusBuildNodes[finishedBuild.id] {
                children.append(cachedNode)
            } else {
                let node = makeNode(.finishedCorpusBuild(finishedBuild.id), usedIdentifiers: &usedIdentifiers) {
                    ReportOutline.configure($0, for: finishedBuild)
                }
                finishedCorpusBuildNodes[finishedBuild.id] = node
                children.append(node)
            }
        }
        finishedCorpusBuildNodes = finishedCorpusBuildNodes.filter { finishedBuildIdentifiers.contains($0.key) }

        var categoryNode: ReportNode?
        if !children.isEmpty {
            categoryNode = makeNode(.category(.searchableInterfaces), children: children, usedIdentifiers: &usedIdentifiers) {
                $0.update(icon: ReportOutline.corpusIcon, title: "Searchable Interfaces")
            }
        }
        dropCellViewModels(of: .searchableInterfaces, except: usedIdentifiers)
        return categoryNode
    }

    /// The Cross References category, or `nil` when it has nothing to show: a row saying the
    /// engine's process cannot prepare them, the images queued or being prepared, then the ended
    /// preparations. Turned off, it has no row saying so, unlike the other kinds: queries scan
    /// instead, so nothing stops working and there is no background work to report.
    func crossReferenceCategory(
        states: [String: CrossReferencePreparationState],
        followedImagePaths: Set<String>,
        finishedPreparations: [CrossReferenceFinishedPreparation],
        isUnsupportedByEngine: Bool,
        isEnabled: Bool
    ) -> ReportNode? {
        var usedIdentifiers: Set<ReportNodeIdentifier> = []
        var children: [ReportNode] = []
        if isEnabled, isUnsupportedByEngine {
            children.append(makeNode(.unsupportedByEngine(.crossReferences), usedIdentifiers: &usedIdentifiers) {
                ReportOutline.configureUnsupportedCrossReferenceRow($0)
            })
        }
        // The images being prepared first, then the waiting ones by name.
        let activePreparations = states.filter(\.value.isActive).sorted { leftEntry, rightEntry in
            let leftIsPreparing = ReportOutline.isPreparing(leftEntry.value)
            let rightIsPreparing = ReportOutline.isPreparing(rightEntry.value)
            if leftIsPreparing != rightIsPreparing {
                return leftIsPreparing
            }
            return FindScope.imageName(of: leftEntry.key) < FindScope.imageName(of: rightEntry.key)
        }
        for (imagePath, state) in activePreparations {
            children.append(makeNode(.crossReferencePreparation(imagePath: imagePath), usedIdentifiers: &usedIdentifiers) {
                ReportOutline.configure($0, forCrossReferencesOf: imagePath, state: state, isFollowed: followedImagePaths.contains(imagePath))
            })
        }
        var finishedPreparationIdentifiers: Set<UUID> = []
        for finishedPreparation in finishedPreparations {
            finishedPreparationIdentifiers.insert(finishedPreparation.id)
            if let cachedNode = finishedCrossReferencePreparationNodes[finishedPreparation.id] {
                children.append(cachedNode)
            } else {
                let node = makeNode(.finishedCrossReferencePreparation(finishedPreparation.id), usedIdentifiers: &usedIdentifiers) {
                    ReportOutline.configure($0, for: finishedPreparation)
                }
                finishedCrossReferencePreparationNodes[finishedPreparation.id] = node
                children.append(node)
            }
        }
        finishedCrossReferencePreparationNodes = finishedCrossReferencePreparationNodes.filter { finishedPreparationIdentifiers.contains($0.key) }

        var categoryNode: ReportNode?
        if !children.isEmpty {
            categoryNode = makeNode(.category(.crossReferences), children: children, usedIdentifiers: &usedIdentifiers) {
                $0.update(icon: ReportOutline.crossReferenceIcon, title: "Cross References")
            }
        }
        dropCellViewModels(of: .crossReferences, except: usedIdentifiers)
        return categoryNode
    }

    // MARK: - Nodes

    private func makeBatchNode(
        _ batch: RuntimeIndexingBatch,
        reusingCellViewModelsOf previousNode: ReportNode? = nil,
        usedIdentifiers: inout Set<ReportNodeIdentifier>
    ) -> ReportNode {
        var previousCellViewModels: [ReportNodeIdentifier: ReportCellViewModel] = [:]
        if let previousNode {
            previousCellViewModels[previousNode.identifier] = previousNode.cellViewModel
            for child in previousNode.children {
                previousCellViewModels[child.identifier] = child.cellViewModel
            }
        }
        var items: [ReportNode] = []
        if ReportOutline.showsItems(of: batch) {
            for item in batch.items {
                items.append(makeNode(.indexingItem(batchID: batch.id, imagePath: item.id), previousCellViewModels: previousCellViewModels, usedIdentifiers: &usedIdentifiers) {
                    ReportOutline.configure($0, for: item)
                })
            }
        }
        return makeNode(.indexingBatch(batch.id), children: items, previousCellViewModels: previousCellViewModels, usedIdentifiers: &usedIdentifiers) {
            ReportOutline.configure($0, for: batch)
        }
    }

    private func makeNode(
        _ identifier: ReportNodeIdentifier,
        children: [ReportNode] = [],
        previousCellViewModels: [ReportNodeIdentifier: ReportCellViewModel] = [:],
        usedIdentifiers: inout Set<ReportNodeIdentifier>,
        configure: (ReportCellViewModel) -> Void
    ) -> ReportNode {
        let cellViewModel = cellViewModelsByIdentifier[identifier]
            ?? previousCellViewModels[identifier]
            ?? ReportCellViewModel(identifier: identifier)
        cellViewModelsByIdentifier[identifier] = cellViewModel
        usedIdentifiers.insert(identifier)
        configure(cellViewModel)
        builtNodeCount += 1
        return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
    }

    /// Drops the cell ViewModels of `category`'s rows that this rebuild did not make. The other
    /// kind was not rebuilt, so its rows keep theirs; a reused finished subtree holds its own.
    private func dropCellViewModels(of category: ReportCategory, except usedIdentifiers: Set<ReportNodeIdentifier>) {
        cellViewModelsByIdentifier = cellViewModelsByIdentifier.filter { identifier, _ in
            identifier.category != category || usedIdentifiers.contains(identifier)
        }
    }
}
