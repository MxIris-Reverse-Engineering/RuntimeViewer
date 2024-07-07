#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

public class SidebarImageCellViewModel: NSObject {
    let runtimeObject: RuntimeObjectType

    @Observed
    public private(set) var icon: NSUIImage?

    @Observed
    public private(set) var name: NSAttributedString

    public init(runtimeObject: RuntimeObjectType) {
        self.runtimeObject = runtimeObject
        self.icon = runtimeObject.icon
        self.name = NSAttributedString {
            AText(runtimeObject.name)
                .font(.systemFont(ofSize: 13))
                .foregroundColor(.labelColor)
        }
        super.init()
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
