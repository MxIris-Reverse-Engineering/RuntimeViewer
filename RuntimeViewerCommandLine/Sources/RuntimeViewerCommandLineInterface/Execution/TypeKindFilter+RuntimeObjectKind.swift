import Foundation
import RuntimeViewerCore

extension TypeKindFilter {
    /// Whether a runtime object's kind falls under this filter.
    public func matches(_ kind: RuntimeObjectKind) -> Bool {
        switch (self, kind) {
        case (.cStruct, .c(.struct)), (.cUnion, .c(.union)):
            return true
        case (.objcClass, .objc(.type(.class))), (.objcProtocol, .objc(.type(.protocol))):
            return true
        case (.objcCategory, .objc(.category)):
            return true
        case (.swiftClass, .swift(.type(.class))), (.swiftStruct, .swift(.type(.struct))),
             (.swiftEnum, .swift(.type(.enum))), (.swiftProtocol, .swift(.type(.protocol))),
             (.swiftTypeAlias, .swift(.type(.typeAlias))):
            return true
        case (.swiftExtension, .swift(.extension)), (.swiftConformance, .swift(.conformance)):
            return true
        default:
            return false
        }
    }

    /// Whether the object passes a set of filters; an empty set passes everything.
    public static func filters(_ filters: [TypeKindFilter], accept kind: RuntimeObjectKind) -> Bool {
        filters.isEmpty || filters.contains { $0.matches(kind) }
    }
}
