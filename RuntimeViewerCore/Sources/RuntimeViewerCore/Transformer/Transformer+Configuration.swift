import Foundation
public import OutputTransformer
public import ObjCOutputTransformer
public import SwiftOutputTransformer

// MARK: - Aggregated Configuration

extension Transformer {
    /// Aggregated configuration for every transformer module, used for
    /// persistence.
    ///
    /// This lives here rather than library-side because it is the only place
    /// that spans both halves: the ObjC modules ship with MachOObjCSection and
    /// the Swift ones with MachOSwiftSection, and nothing but RuntimeViewer
    /// needs to persist and edit them as a single unit.
    public struct Configuration: Sendable, Equatable, Hashable, Codable {
        public var objc: Transformer.ObjCConfiguration
        public var swift: Transformer.SwiftConfiguration

        public init(
            objc: Transformer.ObjCConfiguration = .init(),
            swift: Transformer.SwiftConfiguration = .init()
        ) {
            self.objc = objc
            self.swift = swift
        }

        // Missing-key-tolerant decoding (compatible with the previous
        // MetaCodable `@Default(_:)` persistence).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.objc = try container.decodeIfPresent(ObjCConfiguration.self, forKey: .objc) ?? .init()
            self.swift = try container.decodeIfPresent(SwiftConfiguration.self, forKey: .swift) ?? .init()
        }

        public static let `default` = Self()

        /// Whether any module is enabled.
        public var hasEnabledModules: Bool {
            objc.hasEnabledModules || swift.hasEnabledModules
        }
    }
}
