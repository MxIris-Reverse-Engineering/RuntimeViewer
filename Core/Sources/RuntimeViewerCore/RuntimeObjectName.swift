import MemberwiseInit
import SwiftStdlibToolbox

@Equatable
@MemberwiseInit(.public)
public final class RuntimeObjectName: Codable, Hashable, Identifiable, Sendable {
    public let name: String

    public let displayName: String
    
    public let kind: RuntimeObjectKind

    public let imagePath: String

    public let children: [RuntimeObjectName]
    
    public var id: RuntimeObjectName { self }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }
}

extension RuntimeObjectName: ComparableBuildable {
    public static let comparableDefinition = makeComparable {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.displayName)
    }
}
