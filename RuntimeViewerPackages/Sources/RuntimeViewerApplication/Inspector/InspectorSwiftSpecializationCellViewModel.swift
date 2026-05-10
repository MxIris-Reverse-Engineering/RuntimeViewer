#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RxAppKit
#endif

#if canImport(UIKit)
import UIKit
#endif

import Foundation
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures

public final class InspectorSwiftSpecializationCellViewModel: NSObject, @unchecked Sendable {
    public let runtimeObject: RuntimeObject

    @Observed
    public private(set) var name: NSAttributedString

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        self.name = NSAttributedString {
            AText(runtimeObject.displayName)
                .foregroundColor(.labelColor)
                .font(.systemFont(ofSize: 13))
                .paragraphStyle(NSMutableParagraphStyle().then { $0.lineBreakMode = .byTruncatingTail })
        }
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorSwiftSpecializationCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObject { runtimeObject }

    public func isContentEqual(to source: InspectorSwiftSpecializationCellViewModel) -> Bool {
        runtimeObject == source.runtimeObject
    }
}

#endif
