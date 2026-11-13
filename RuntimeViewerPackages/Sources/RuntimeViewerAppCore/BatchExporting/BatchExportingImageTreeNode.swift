import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// One row of the batch export image picker: an image, or a folder on the way to images.
///
/// Rows are built once per picker and live as long as it does. A search only changes which
/// children a folder reports and what its checkbox shows, and `BatchExportingImageTree` is the
/// one that changes them.
public final class BatchExportingImageTreeNode: NSObject, OutlineNodeType, @unchecked Sendable {
    public enum SelectionState: Sendable {
        case unselected
        case partiallySelected
        case selected
    }

    /// What a row's checkbox and count show. Both count only the images the current query
    /// matches.
    public struct Selection: Equatable, Sendable {
        public var state: SelectionState

        /// The selected images among the matching ones under this row; 0 or 1 for an image.
        public var selectedImageCount: Int

        /// The images under this row the current query matches; 1 for a matching image.
        public var matchingImageCount: Int
    }

    /// The image-tree node this row stands for, kept for display.
    public let imageNode: RuntimeImageNode

    /// The path dyld knows the image by; `nil` for a folder.
    public let imagePath: String?

    /// The children the outline shows: those holding at least one matching image, in name order.
    public private(set) var children: [BatchExportingImageTreeNode] = []

    @RxObserved
    public private(set) var selection: Selection = Selection(state: .unselected, selectedImageCount: 0, matchingImageCount: 0)

    /// Every child, matching or not, in name order.
    let allChildren: [BatchExportingImageTreeNode]

    /// The image's position in `BatchExportingImageTree.imageNodes`; `nil` for a folder.
    let imageIndex: Int?

    /// How many images under this row the current query matches.
    private(set) var matchingImageCount = 0

    /// Builds a root folder and everything under it, appending every image to `imageNodes` in
    /// display order. A root never stands for an image, not even an empty one: its path is the
    /// synthetic root component ("Others"), not a dyld path.
    convenience init(rootImageNode: RuntimeImageNode, imageNodes: inout [BatchExportingImageTreeNode]) {
        self.init(imageNode: rootImageNode, isRoot: true, imageNodes: &imageNodes)
    }

    private init(imageNode: RuntimeImageNode, isRoot: Bool, imageNodes: inout [BatchExportingImageTreeNode]) {
        self.imageNode = imageNode
        if !isRoot, imageNode.isLeaf {
            self.imagePath = imageNode.path
            self.imageIndex = imageNodes.count
            self.allChildren = []
            super.init()
            imageNodes.append(self)
        } else {
            self.imagePath = nil
            self.imageIndex = nil
            // The order the sidebar's image list uses.
            self.allChildren = imageNode.children
                .sorted { $0.name < $1.name }
                .map { BatchExportingImageTreeNode(imageNode: $0, isRoot: false, imageNodes: &imageNodes) }
            super.init()
        }
    }

    public var name: String {
        imageNode.name
    }

    public var isImage: Bool {
        imagePath != nil
    }

    /// Recomputes which children are shown and how many images under this row match.
    /// - Returns: The number of matching images under this row.
    @discardableResult
    func installMatches(_ isMatchingImage: (Int) -> Bool) -> Int {
        if let imageIndex {
            matchingImageCount = isMatchingImage(imageIndex) ? 1 : 0
        } else {
            var matchingChildren: [BatchExportingImageTreeNode] = []
            var childrenMatchingImageCount = 0
            for child in allChildren {
                let childMatchingImageCount = child.installMatches(isMatchingImage)
                if childMatchingImageCount > 0 {
                    matchingChildren.append(child)
                    childrenMatchingImageCount += childMatchingImageCount
                }
            }
            children = matchingChildren
            matchingImageCount = childrenMatchingImageCount
        }
        return matchingImageCount
    }

    /// Recomputes the checkbox of this row and of every shown row beneath it.
    /// - Returns: The number of selected images among the matching ones under this row.
    @discardableResult
    func installSelection(_ selectedImagePaths: Set<String>) -> Int {
        let selectedImageCount: Int
        if let imagePath {
            selectedImageCount = selectedImagePaths.contains(imagePath) ? 1 : 0
        } else {
            selectedImageCount = children.reduce(0) { $0 + $1.installSelection(selectedImagePaths) }
        }
        let state: SelectionState = if selectedImageCount == 0 {
            .unselected
        } else if selectedImageCount < matchingImageCount {
            .partiallySelected
        } else {
            .selected
        }
        let updatedSelection = Selection(state: state, selectedImageCount: selectedImageCount, matchingImageCount: matchingImageCount)
        // The setter publishes even an equal value, and a click leaves most rows as they were.
        if selection != updatedSelection {
            selection = updatedSelection
        }
        return selectedImageCount
    }

    /// Appends the paths of the matching images under this row, in display order.
    func appendMatchingImagePaths(to imagePaths: inout [String]) {
        if let imagePath {
            if matchingImageCount > 0 {
                imagePaths.append(imagePath)
            }
        } else {
            for child in children {
                child.appendMatchingImagePaths(to: &imagePaths)
            }
        }
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension BatchExportingImageTreeNode: Differentiable {}

#endif
