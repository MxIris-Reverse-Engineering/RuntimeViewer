import Foundation
import MetaCodable
public import Semantic

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

        public init(cType: CType = .init()) {
            self.cType = cType
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
        @Default(ifMissing: Transformer.SwiftTypeLayout())
        public var swiftTypeLayout: Transformer.SwiftTypeLayout

        public init(
            swiftFieldOffset: SwiftFieldOffset = .init(),
            swiftTypeLayout: SwiftTypeLayout = .init()
        ) {
            self.swiftFieldOffset = swiftFieldOffset
            self.swiftTypeLayout = swiftTypeLayout
        }
    }
}

// MARK: - Aggregated Configuration

extension Transformer {
    /// Aggregated configuration for all transformer modules (used for persistence).
    @Codable
    public struct Configuration: Sendable, Equatable, Hashable {
        @Default(ifMissing: Transformer.ObjCConfiguration())
        public var objc: Transformer.ObjCConfiguration
        @Default(ifMissing: Transformer.SwiftConfiguration())
        public var swift: Transformer.SwiftConfiguration

        public init(
            objc: ObjCConfiguration = .init(),
            swift: SwiftConfiguration = .init()
        ) {
            self.objc = objc
            self.swift = swift
        }

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            objc.cType.isEnabled || swift.swiftFieldOffset.isEnabled || swift.swiftTypeLayout.isEnabled
        }
    }
}
