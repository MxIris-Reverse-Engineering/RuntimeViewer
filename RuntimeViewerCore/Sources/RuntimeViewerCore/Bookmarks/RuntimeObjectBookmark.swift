import Foundation
import MemberwiseInit

/// A bookmarked runtime object, stored under its peer's
/// `RuntimeBookmarkScope`. See ``RuntimeImageBookmark`` for why there is no
/// source field.
@MemberwiseInit(.public)
public struct RuntimeObjectBookmark: Codable, Hashable {
    public let object: RuntimeObject
}
