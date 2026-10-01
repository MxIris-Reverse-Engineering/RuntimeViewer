import Foundation
import RuntimeViewerCore

/// The images a batch export picks from, laid out as the sidebar's image list lays them out
/// ("Dyld Shared Cache", "Others"), and filtered by a query.
///
/// The selection is not stored here: the export state owns it as a set of image paths. This type
/// answers how that set looks under the current query — every row's checkbox — and how a click
/// changes it. A folder's checkbox, Select All and Deselect All act only on the images the query
/// matches, so searching and then checking a folder selects the intersection, and the images the
/// search hides keep whatever state they had.
@MainActor
public final class BatchExportingImageTree {
    /// Every root folder in the engine's order, holding matching images or not.
    public let rootNodes: [BatchExportingImageTreeNode]

    /// Every image, in display order.
    public let imageNodes: [BatchExportingImageTreeNode]

    /// The root folders holding at least one matching image: what the outline shows.
    public private(set) var matchingRootNodes: [BatchExportingImageTreeNode] = []

    /// The paths of the images the current query matches, in display order.
    public private(set) var matchingImagePaths: [String] = []

    /// The query the tree currently reflects.
    public private(set) var query = BatchExportingImageQuery()

    /// Why the current query matches nothing: its text is not a valid regular expression.
    /// `nil` whenever the query compiled.
    public private(set) var invalidQueryReason: String?

    private let matchCandidates: [BatchExportingImageMatchCandidate]

    /// The selection the checkboxes were last computed from, kept to recompute them when the
    /// query changes which rows are shown.
    private var selectedImagePaths: Set<String> = []

    /// Bumped by every `apply(_:)`, so that a slow match never lands on top of a newer query.
    private var latestQueryGeneration = 0

    private enum MatchResult: Sendable {
        case everyImage
        case matchingImages(isMatchingByImageIndex: [Bool])
        case invalidQuery(reason: String)
    }

    public init(imageRootNodes: [RuntimeImageNode]) {
        var imageNodes: [BatchExportingImageTreeNode] = []
        rootNodes = imageRootNodes.map { BatchExportingImageTreeNode(rootImageNode: $0, imageNodes: &imageNodes) }
        self.imageNodes = imageNodes
        // One candidate per image, at the image's own index.
        matchCandidates = imageNodes.map { BatchExportingImageMatchCandidate(name: $0.name, path: $0.imagePath ?? "") }
        installMatches { _ in true }
    }

    /// Matches `query` against every image and installs the result. The matching runs off the
    /// main actor; a blank query installs without suspending.
    /// - Returns: `false` when a newer call, or cancellation, superseded this one. The tree is then
    ///   left as the newer call leaves it.
    @discardableResult
    public func apply(_ query: BatchExportingImageQuery) async -> Bool {
        latestQueryGeneration &+= 1
        let queryGeneration = latestQueryGeneration
        let matchResult: MatchResult
        if query.isEmpty {
            matchResult = .everyImage
        } else {
            guard let computedMatchResult = await Self.matchImages(matchCandidates, against: query) else {
                return false
            }
            matchResult = computedMatchResult
        }
        guard queryGeneration == latestQueryGeneration, !Task.isCancelled else { return false }

        self.query = query
        switch matchResult {
        case .everyImage:
            invalidQueryReason = nil
            installMatches { _ in true }
        case .matchingImages(let isMatchingByImageIndex):
            invalidQueryReason = nil
            installMatches { isMatchingByImageIndex[$0] }
        case .invalidQuery(let reason):
            invalidQueryReason = reason
            installMatches { _ in false }
        }
        return true
    }

    /// Recomputes the checkbox of every shown row for `selectedImagePaths`.
    public func updateSelection(_ selectedImagePaths: Set<String>) {
        self.selectedImagePaths = selectedImagePaths
        for rootNode in matchingRootNodes {
            rootNode.installSelection(selectedImagePaths)
        }
    }

    /// The selection after a click on `node`'s checkbox: every matching image under it becomes
    /// selected, unless all of them already are, in which case all of them become unselected.
    public func selection(afterToggling node: BatchExportingImageTreeNode, in selectedImagePaths: Set<String>) -> Set<String> {
        var toggledImagePaths: [String] = []
        node.appendMatchingImagePaths(to: &toggledImagePaths)
        if toggledImagePaths.allSatisfy(selectedImagePaths.contains) {
            return selectedImagePaths.subtracting(toggledImagePaths)
        } else {
            return selectedImagePaths.union(toggledImagePaths)
        }
    }

    /// The selection after Select All: every matching image added.
    public func selection(afterSelectingAllMatchingImagesIn selectedImagePaths: Set<String>) -> Set<String> {
        selectedImagePaths.union(matchingImagePaths)
    }

    /// The selection after Deselect All: every matching image removed.
    public func selection(afterDeselectingAllMatchingImagesIn selectedImagePaths: Set<String>) -> Set<String> {
        selectedImagePaths.subtracting(matchingImagePaths)
    }

    private func installMatches(_ isMatchingImage: (Int) -> Bool) {
        for rootNode in rootNodes {
            rootNode.installMatches(isMatchingImage)
        }
        matchingRootNodes = rootNodes.filter { $0.matchingImageCount > 0 }
        var matchingImagePaths: [String] = []
        for rootNode in matchingRootNodes {
            rootNode.appendMatchingImagePaths(to: &matchingImagePaths)
        }
        self.matchingImagePaths = matchingImagePaths
        updateSelection(selectedImagePaths)
    }

    /// - Returns: `nil` when cancelled part-way through.
    @concurrent
    private nonisolated static func matchImages(
        _ matchCandidates: [BatchExportingImageMatchCandidate],
        against query: BatchExportingImageQuery
    ) async -> MatchResult? {
        let matcher: BatchExportingImageMatcher
        do throws(BatchExportingImageMatcher.InvalidRegularExpression) {
            matcher = try BatchExportingImageMatcher(query: query)
        } catch {
            return .invalidQuery(reason: error.reason)
        }
        var isMatchingByImageIndex: [Bool] = []
        isMatchingByImageIndex.reserveCapacity(matchCandidates.count)
        for matchCandidate in matchCandidates {
            // A regular expression over thousands of paths takes long enough for the next
            // keystroke to arrive; stop rather than finish a result nobody will install.
            if isMatchingByImageIndex.count.isMultiple(of: 256), Task.isCancelled {
                return nil
            }
            isMatchingByImageIndex.append(matcher.matches(matchCandidate))
        }
        return .matchingImages(isMatchingByImageIndex: isMatchingByImageIndex)
    }
}
