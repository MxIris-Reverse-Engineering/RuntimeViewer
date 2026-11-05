import Foundation
import FoundationToolbox
import MachOKit

/// Codable equivalent of the BFS metadata tuple. Tuples can't conform to
/// `Codable`, so the on-wire form uses this struct and the public
/// `dependencies(...)` API repacks to tuples at the dispatch seam.
public struct RuntimeDependencyEntry: Codable, Sendable {
    public let installName: String
    public let resolvedPath: String?

    public init(installName: String, resolvedPath: String?) {
        self.installName = installName
        self.resolvedPath = resolvedPath
    }
}
