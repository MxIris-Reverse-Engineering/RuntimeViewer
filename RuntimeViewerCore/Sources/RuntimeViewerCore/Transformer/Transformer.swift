import Foundation
import MetaCodable
import Semantic

// MARK: - Transformer Namespace

/// Namespace for all transformer-related types.
public enum Transformer {}

// MARK: - Module Protocol

extension Transformer {
    /// A transformer module that converts input to output.
    ///
    /// Each module defines:
    /// - `Parameter`: Predefined parameters displayed in Settings UI for user configuration.
    /// - `Input`: Input passed by the caller at runtime.
    /// - `Output`: Output returned to the caller.
    ///
    /// To add a new module:
    /// 1. Create a struct conforming to `Transformer.Module`
    /// 2. Add it as a property in the appropriate configuration
    public protocol Module: Codable, Sendable, Hashable {
        /// Predefined parameters, displayed in Settings UI for user configuration.
        associatedtype Parameter: CaseIterable & Hashable & Sendable

        /// Input passed by the caller at runtime.
        associatedtype Input

        /// Output returned to the caller.
        associatedtype Output

        /// Display name for Settings UI.
        static var displayName: String { get }

        /// Whether this module is enabled.
        var isEnabled: Bool { get set }

        /// Applies this module's transformation.
        func transform(_ input: Input) -> Output
    }
}

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

// MARK: - Swift Configuration

extension Transformer {
    /// Configuration for Swift-specific transformer modules.
    @Codable
    public struct SwiftConfiguration: Sendable, Equatable, Hashable {
        @Default(ifMissing: Transformer.SwiftFieldOffset())
        public var swiftFieldOffset: Transformer.SwiftFieldOffset
        @Default(ifMissing: Transformer.SwiftVTableOffset())
        public var swiftVTableOffset: Transformer.SwiftVTableOffset
        @Default(ifMissing: Transformer.SwiftMemberAddress())
        public var swiftMemberAddress: Transformer.SwiftMemberAddress
        @Default(ifMissing: Transformer.SwiftTypeLayout())
        public var swiftTypeLayout: Transformer.SwiftTypeLayout
        @Default(ifMissing: Transformer.SwiftEnumLayout())
        public var swiftEnumLayout: Transformer.SwiftEnumLayout

        public init(
            swiftFieldOffset: SwiftFieldOffset = .init(),
            swiftVTableOffset: SwiftVTableOffset = .init(),
            swiftMemberAddress: SwiftMemberAddress = .init(),
            swiftTypeLayout: SwiftTypeLayout = .init(),
            swiftEnumLayout: SwiftEnumLayout = .init()
        ) {
            self.swiftFieldOffset = swiftFieldOffset
            self.swiftVTableOffset = swiftVTableOffset
            self.swiftMemberAddress = swiftMemberAddress
            self.swiftTypeLayout = swiftTypeLayout
            self.swiftEnumLayout = swiftEnumLayout
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
            objc.cType.isEnabled || objc.ivarOffset.isEnabled || swift.swiftFieldOffset.isEnabled || swift.swiftVTableOffset.isEnabled || swift.swiftMemberAddress.isEnabled || swift.swiftTypeLayout.isEnabled || swift.swiftEnumLayout.isEnabled
        }
    }
}
