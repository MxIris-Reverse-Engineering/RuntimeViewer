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

public final class InspectorRelationshipsCellViewModel: NSObject, @unchecked Sendable {
    public let runtimeObject: RuntimeObject

    @RxObserved
    public private(set) var appearance: RuntimeObjectCellAppearance

    public init(runtimeObject: RuntimeObject) {
        self.runtimeObject = runtimeObject
        self.appearance = .inspectorRow(for: runtimeObject)
        super.init()
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension InspectorRelationshipsCellViewModel: Differentiable {
    public var differenceIdentifier: RuntimeObjectKey { runtimeObject.key }

    public func isContentEqual(to source: InspectorRelationshipsCellViewModel) -> Bool {
        runtimeObject.hasSameContent(as: source.runtimeObject)
    }
}

extension InspectorRelationshipsCellViewModel: RuntimeObjectCellDisplayable {
    public var appearanceDriver: Driver<RuntimeObjectCellAppearance> { $appearance.asDriver() }
}

#endif
