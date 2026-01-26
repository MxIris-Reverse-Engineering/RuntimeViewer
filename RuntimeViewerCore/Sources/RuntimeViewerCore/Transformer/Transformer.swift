public import Foundation
import MetaCodable
public import Semantic

// MARK: - Transformer Namespace

/// Namespace for all transformer-related types.
public enum Transformer {}

// MARK: - Module Protocol

extension Transformer {
    /// A transformer module that can process semantic strings.
    ///
    /// Conform to this protocol to create new transformer modules.
    /// Each module is responsible for a specific type of transformation.
    ///
    /// To add a new module:
    /// 1. Create a struct conforming to `Transformer.Module`
    /// 2. Add it as a property in `Transformer.Configuration`
    /// That's it - no other changes needed.
    public protocol Module: Codable, Sendable, Hashable {
        /// Unique identifier for this module type.
        static var moduleID: String { get }

        /// Display name for Settings UI.
        static var displayName: String { get }

        /// Whether this module is enabled.
        var isEnabled: Bool { get set }

        /// Applies this module's transformation to the semantic string.
        func apply(to interface: SemanticString, context: Context) -> SemanticString
    }
}

// MARK: - Context

extension Transformer {
    /// Context information passed to modules during transformation.
    public struct Context: Sendable {
        public let imagePath: String
        public let objectName: String

        public init(imagePath: String, objectName: String) {
            self.imagePath = imagePath
            self.objectName = objectName
        }
    }
}

// MARK: - Configuration

extension Transformer {
    /// Aggregated configuration for all transformer modules.
    ///
    /// To add a new module, simply add a new property here.
    /// The `apply` method automatically picks up all modules via reflection.
    public struct Configuration: Sendable, Equatable, Hashable, Codable {
        public var cType: Transformer.CType
        public var fieldOffset: Transformer.FieldOffset

        // ========================================
        // To add new modules, add properties here:
        // public var newModule: NewModule
        // ========================================

        public init(
            cType: Transformer.CType = .init(),
            fieldOffset: Transformer.FieldOffset = .init()
        ) {
            self.cType = cType
            self.fieldOffset = fieldOffset
        }

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            allModules.contains { $0.isEnabled }
        }

        /// Applies all enabled modules to the interface.
        public func apply(to interface: SemanticString, context: Context) -> SemanticString {
            allModules.reduce(interface) { result, module in
                module.isEnabled ? module.apply(to: result, context: context) : result
            }
        }

        /// All modules in this configuration (via reflection).
        private var allModules: [any Module] {
            Mirror(reflecting: self).children.compactMap { $0.value as? any Module }
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
