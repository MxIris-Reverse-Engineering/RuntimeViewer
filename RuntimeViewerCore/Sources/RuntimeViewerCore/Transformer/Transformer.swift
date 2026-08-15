import Foundation
import MetaCodable
@_exported public import OutputTransformer
@_exported public import SwiftOutputTransformer

/// The Swift-side transformer template mechanism (comment token templates,
/// presets, and `SwiftConfiguration`) moved library-side, so the templates
/// render inside the library and RuntimeViewer keeps only the settings UI. It
/// arrives from two packages: the shared `Transformer` namespace and the
/// `Module` protocol live in swift-semantic-string's `OutputTransformer`, while
/// the Swift-specific modules live in MachOSwiftSection's
/// `SwiftOutputTransformer`. Splitting them is what lets the ObjC-side modules
/// extend the same namespace without a consumer having to qualify every
/// reference. These re-exports keep every existing `Transformer.…` reference
/// compiling unchanged.
///
/// The ObjC-side modules (`CType`, `ObjCIvarOffset`) and the aggregate
/// persistence `Configuration` remain here for now (declared as extensions of
/// the imported namespace), pending a library-side home for the ObjC
/// rendering pipeline.

// MARK: - ObjC Configuration

extension Transformer {
    /// Configuration for ObjC-specific transformer modules.
    @Codable
    public struct ObjCConfiguration: Sendable, Equatable, Hashable {
        @Default(ifMissing: Transformer.CType())
        public var cType: Transformer.CType
        @Default(ifMissing: Transformer.ObjCIvarOffset())
        public var ivarOffset: Transformer.ObjCIvarOffset

        public init(cType: CType = .init(), ivarOffset: ObjCIvarOffset = .init()) {
            self.cType = cType
            self.ivarOffset = ivarOffset
        }
    }
}

// MARK: - Aggregated Configuration

extension Transformer {
    /// Aggregated configuration for all transformer modules (used for persistence).
    @Codable
    @MemberInit
    public struct Configuration: Sendable, Equatable, Hashable {
        @Default(Transformer.ObjCConfiguration())
        public var objc: Transformer.ObjCConfiguration
        @Default(Transformer.SwiftConfiguration())
        public var swift: Transformer.SwiftConfiguration

        public static let `default` = Self()

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            objc.cType.isEnabled || objc.ivarOffset.isEnabled || swift.hasEnabledModules
        }
    }
}
