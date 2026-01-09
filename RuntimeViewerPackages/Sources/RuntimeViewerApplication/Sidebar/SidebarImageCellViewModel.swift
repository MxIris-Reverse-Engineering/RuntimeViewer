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

public final class SidebarImageCellViewModel: NSObject, OutlineNodeType, FilterableItem, @unchecked Sendable {
    public let runtimeObject: RuntimeObjectName

    public let forOpenQuickly: Bool
    
    public weak var parent: SidebarImageCellViewModel?

    public var children: [SidebarImageCellViewModel] { _filteredChildren }

    public var isLeaf: Bool { children.isEmpty }

    private lazy var _filteredChildren: [SidebarImageCellViewModel] = _children

    private lazy var _children: [SidebarImageCellViewModel] = {
        let children = runtimeObject.children.map { SidebarImageCellViewModel(runtimeObject: $0, parent: self, forOpenQuickly: forOpenQuickly) }
        return children.sorted { $0.runtimeObject.displayName < $1.runtimeObject.displayName }
    }()

    public private(set) lazy var currentAndChildrenNames: String = {
        let childrenNames = _children.map { $0.currentAndChildrenNames }.joined(separator: " ")
        if childrenNames.isEmpty {
            return runtimeObject.displayName
        } else {
            return "\(runtimeObject.displayName) \(childrenNames)"
        }
    }()

    @Dependency(\.appDefaults)
    private var appDefaults

    var filter: String = "" {
        didSet {
            _filteredChildren = FilterEngine.filter(filter, items: _children, mode: appDefaults.filterMode)
        }
    }

    var filterResult: FuzzyFilterResult? {
        didSet {
            if let filterResult {
                let name = NSMutableAttributedString {
                    AText(runtimeObject.displayName)
                        .font(.systemFont(ofSize: fontSize))
                        .foregroundColor(forOpenQuickly ? .secondaryLabelColor : .tertiaryLabelColor)
                        .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
                }

                guard let range = currentAndChildrenNames.ranges(of: runtimeObject.displayName).first else {
                    self.name = name
                    return
                }

                let currentNSRange = NSRange(currentAndChildrenNames.integerRange(from: range))

                filterResult.ranges.forEach { resultNSRange in
                    guard resultNSRange.location >= currentNSRange.location, NSMaxRange(resultNSRange) <= NSMaxRange(currentNSRange) else { return }
                    name.addAttributes([
                        .foregroundColor: NSUIColor.labelColor,
                        .font: NSUIFont.systemFont(ofSize: fontSize, weight: .semibold),
                    ], range: resultNSRange)
                }
                self.name = name
            } else {
                name = defaultAttributedName()
            }
        }
    }

    var filterableString: String {
        currentAndChildrenNames
    }

    private static let normalFontSize: CGFloat = 13
    
    private static let openQuicklyFontSize: CGFloat = 16
    
    private var fontSize: CGFloat {
        forOpenQuickly ? Self.openQuicklyFontSize : Self.normalFontSize
    }
    
    @Observed
    public private(set) var primaryIcon: NSUIImage?

    @Observed
    public private(set) var secondaryIcon: NSUIImage?

    @Observed
    public private(set) var name: NSAttributedString = .init()

    @NSAttributedStringBuilder
    private func defaultAttributedName() -> NSAttributedString {
        AText(runtimeObject.displayName)
            .font(.systemFont(ofSize: fontSize))
            .foregroundColor(.labelColor)
            .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
    }

    public init(runtimeObject: RuntimeObjectName, parent: SidebarImageCellViewModel?, forOpenQuickly: Bool) {
        self.runtimeObject = runtimeObject
        self.forOpenQuickly = forOpenQuickly
        super.init()
        self.parent = parent
        if forOpenQuickly {
            self.primaryIcon = runtimeObject.kind.icon(size: 24)
            self.secondaryIcon = runtimeObject.secondaryKind?.icon(size: 24)
        } else {
            self.primaryIcon = runtimeObject.kind.icon
            self.secondaryIcon = runtimeObject.secondaryKind?.icon
        }
        self.name = defaultAttributedName()
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
