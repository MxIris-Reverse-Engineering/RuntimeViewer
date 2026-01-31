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
    /// 2. Add it as a property in `Transformer.Configuration`
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

// MARK: - Configuration

extension Transformer {
    /// Aggregated configuration for all transformer modules.
    @Codable
    public struct Configuration: Sendable, Equatable, Hashable {
        @Default(ifMissing: Transformer.CType())
        public var cType: Transformer.CType
        @Default(ifMissing: Transformer.SwiftFieldOffset())
        public var swiftFieldOffset: Transformer.SwiftFieldOffset
        @Default(ifMissing: Transformer.SwiftTypeLayout())
        public var swiftTypeLayout: Transformer.SwiftTypeLayout

        public init(
            cType: CType = .init(),
            swiftFieldOffset: SwiftFieldOffset = .init(),
            swiftTypeLayout: SwiftTypeLayout = .init()
        ) {
            self.cType = cType
            self.swiftFieldOffset = swiftFieldOffset
            self.swiftTypeLayout = swiftTypeLayout
        }

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            cType.isEnabled || swiftFieldOffset.isEnabled || swiftTypeLayout.isEnabled
        }

        /// Applies post-processing transformer modules to the interface string.
        /// Note: CType replacement is applied at generation time via ObjCDumpContext.
        public func apply(to interface: SemanticString) -> SemanticString {
            interface
        }
    }
}

// MARK: - Presets

extension Transformer.Configuration {
    public static var disabled: Self { .init() }

    public static var stdint: Self {
        var config = Self()
        config.cType.isEnabled = true
        config.cType.replacements = Transformer.CType.Presets.stdint
        return config
    }

    public static var foundation: Self {
        var config = Self()
        config.cType.isEnabled = true
        config.cType.replacements = Transformer.CType.Presets.foundation
        return config
    }
}
