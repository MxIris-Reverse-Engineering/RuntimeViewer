import MemberwiseInit
public import SwiftStdlibToolbox

@Equatable
@MemberwiseInit(.public)
public struct RuntimeObjectName: Codable, Hashable, Identifiable, Sendable {
    public let name: String

    public let displayName: String
    
    public let kind: RuntimeObjectKind

    public let imagePath: String

    public let children: [RuntimeObjectName]
    
    public var id: RuntimeObjectName { self }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }
    
    public func withImagePath(_ imagePath: String) -> RuntimeObjectName {
        .init(name: name, displayName: displayName, kind: kind, imagePath: imagePath, children: children)
    }
}

extension RuntimeObjectName: ComparableBuildable {
    public static let comparableDefinition = makeComparable {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.displayName)
    }
}
