import MemberwiseInit
public import SwiftStdlibToolbox

@Equatable
@MemberwiseInit(.public)
public struct RuntimeObject: Codable, Hashable, Identifiable, Sendable {
    public let name: String

    public let displayName: String
    
    public let kind: RuntimeObjectKind

    public let secondaryKind: RuntimeObjectKind?
    
    public let imagePath: String

    public let children: [RuntimeObject]
    
    public var id: RuntimeObject { self }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }
    
    public func withImagePath(_ imagePath: String) -> RuntimeObject {
        .init(name: name, displayName: displayName, kind: kind, secondaryKind: secondaryKind, imagePath: imagePath, children: children)
    }
}

extension RuntimeObject: ComparableBuildable {
    public static let comparableDefinition = makeComparable {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.displayName)
    }
}
