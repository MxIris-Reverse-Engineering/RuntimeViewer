#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Ifrit

public final class SidebarImageCellViewModel: NSObject, OutlineNodeType, Searchable {
    public let runtimeObject: RuntimeObjectName

    public weak var parent: SidebarImageCellViewModel?
    
    public var children: [SidebarImageCellViewModel] { _filteredChildren }

    public var isLeaf: Bool { children.isEmpty }

    private lazy var _filteredChildren: [SidebarImageCellViewModel] = _children

    private lazy var _children: [SidebarImageCellViewModel] = {
        let children = runtimeObject.children.map { SidebarImageCellViewModel(runtimeObject: $0, parent: self) }
        return children.sorted { $0.runtimeObject.displayName < $1.runtimeObject.displayName }
    }()

    public private(set) lazy var currentAndChildrenNames: String = {
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        return "\(runtimeObject.displayName) \(childrenNames)"
    }()

    var searchableProperties: [FuseProp] {
        [
            FuseProp(currentAndChildrenNames)
        ]
    }
    
    var filterResult: FuzzySrchResult? {
        didSet {
            if let filterResult {
                let name = defaultAttributedName.mutableCopy() as! NSMutableAttributedString
                guard let range = currentAndChildrenNames.ranges(of: runtimeObject.displayName).first else {
                    self.name = name
                    return
                }
                let nsRange = NSRange(currentAndChildrenNames.integerRange(from: range))
                filterResult.results.flatMap { $0.ranges.map { NSRange($0) } }.forEach { range in
                    guard range.location >= nsRange.location, range.max <= nsRange.max else { return }
                    name.addAttributes([
                        .backgroundColor: NSUIColor.selectedTextBackgroundColor,
                    ], range: range)
                }
                self.name = name
            } else {
                self.name = defaultAttributedName
            }
        }
    }
    
    var filter: String = "" {
        didSet {
            if filter.isEmpty {
                _children.forEach {
                    $0.filter = filter
                    $0.filterResult = nil
                }
                _filteredChildren = _children
            } else {
                _children.forEach { $0.filter = filter }
//                _filteredChildren = _children.filter { $0.currentAndChildrenNames.localizedCaseInsensitiveContains(filter) }
                let fuse = Fuse()
                let results = fuse.searchSync(filter, in: _children, by: \SidebarImageCellViewModel.searchableProperties).sorted(by: { $0.diffScore < $1.diffScore })
                var filteredChildren: [SidebarImageCellViewModel] = []
                for result in results {
                    let cellViewModel = _children[result.index]
                    cellViewModel.filterResult = result
                    filteredChildren.append(cellViewModel)
                }
                _filteredChildren = filteredChildren
                
            }
        }
    }
    @Observed
    public private(set) var icon: NSUIImage?

    @Observed
    public private(set) var name: NSAttributedString = .init()

    @NSAttributedStringBuilder
    var defaultAttributedName: NSAttributedString {
            AText(runtimeObject.displayName)
            .font(.systemFont(ofSize: 13))
                .foregroundColor(.labelColor)
        
    }
    
    public init(runtimeObject: RuntimeObjectName, parent: SidebarImageCellViewModel?) {
        self.runtimeObject = runtimeObject
        self.parent = parent
        self.icon = runtimeObject.kind.icon
        super.init()
        self.name = defaultAttributedName
    }

    public override var hash: Int {
        var hasher = Hasher()
        hasher.combine(runtimeObject)
        return hasher.finalize()
    }

    public override func isEqual(_ object: Any?) -> Bool {
        guard let object = object as? Self else { return false }
        return runtimeObject == object.runtimeObject
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension SidebarImageCellViewModel: Differentiable {}

#endif

extension String {
    
    // MARK: - Index to Int Conversion
    
    /// Converts String.Index to Int (Integer offset).
    /// - Parameter index: The String.Index to convert.
    /// - Returns: The integer offset corresponding to the index.
    func integerIndex(of index: String.Index) -> Int {
        return self.distance(from: self.startIndex, to: index)
    }
    
    // MARK: - Int to Index Conversion
    
    /// Converts Int (Integer offset) to String.Index.
    /// - Parameter offset: The integer offset.
    /// - Returns: The corresponding String.Index, or nil if out of bounds.
    func index(at offset: Int) -> String.Index? {
        guard offset >= 0 && offset <= self.count else { return nil }
        return self.index(self.startIndex, offsetBy: offset)
    }
    
    // MARK: - Range<String.Index> to Range<Int>
    
    /// Converts Range<String.Index> to Range<Int> (NSRange style).
    /// - Parameter range: The range of String.Index.
    /// - Returns: The corresponding Range<Int>.
    func integerRange(from range: Range<String.Index>) -> Range<Int> {
        let start = self.integerIndex(of: range.lowerBound)
        let end = self.integerIndex(of: range.upperBound)
        return start..<end
    }
    
    // MARK: - Range<Int> to Range<String.Index>
    
    /// Converts Range<Int> to Range<String.Index>.
    /// - Parameter range: The range of integers.
    /// - Returns: The corresponding Range<String.Index>, or nil if indices are invalid.
    func indexRange(from range: Range<Int>) -> Range<String.Index>? {
        guard let start = self.index(at: range.lowerBound),
              let end = self.index(at: range.upperBound) else {
            return nil
        }
        return start..<end
    }
}
