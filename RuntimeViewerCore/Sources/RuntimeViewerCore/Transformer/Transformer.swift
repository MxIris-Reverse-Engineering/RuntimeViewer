public import Foundation
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
    public struct Configuration: Sendable, Equatable, Hashable, Codable {
        public var cType: Transformer.CType
        public var fieldOffset: Transformer.FieldOffset

        public init(
            cType: Transformer.CType = .init(),
            fieldOffset: Transformer.FieldOffset = .init()
        ) {
            self.cType = cType
            self.fieldOffset = fieldOffset
        }

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            cType.isEnabled || fieldOffset.isEnabled
        }

        /// Applies all enabled modules to the interface string.
        public func apply(to interface: SemanticString) -> SemanticString {
            var result = interface
            if cType.isEnabled {
                result = cType.transform(result)
            }
            return result
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
