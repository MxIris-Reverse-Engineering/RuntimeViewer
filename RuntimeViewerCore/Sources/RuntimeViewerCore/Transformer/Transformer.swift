import Foundation
import MetaCodable

/// The Swift-side transformer template mechanism (the `Transformer` namespace:
/// comment token templates, presets, the `Module` protocol, and
/// `SwiftConfiguration`) moved library-side into MachOSwiftSection's
/// `SemanticTransformer` module, so the templates render inside the library
/// and RuntimeViewer keeps only the settings UI. This re-export keeps every
/// existing `Transformer.…` reference compiling unchanged.
///
/// The ObjC-side modules (`CType`, `ObjCIvarOffset`) and the aggregate
/// persistence `Configuration` remain here for now (declared as extensions of
/// the imported namespace), pending a library-side home for the ObjC
/// rendering pipeline.
@_exported import SemanticTransformer

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
