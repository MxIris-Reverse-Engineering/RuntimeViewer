import Foundation
import MemberwiseInit
public import RuntimeViewerCommunication

@MemberwiseInit(.public)
public struct RuntimeImageBookmark: Codable {
    public let source: RuntimeSource
    public let imageNode: RuntimeImageNode
}


@MemberwiseInit(.public)
public struct RuntimeObjectBookmark: Codable {
    public let source: RuntimeSource
    public let object: RuntimeObject
}
