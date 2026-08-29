import Foundation
import MemberwiseInit

/// A bookmarked image, stored under its peer's `RuntimeBookmarkScope`.
///
/// Carries no source of its own. The dictionary key already says which peer a
/// bookmark belongs to, and holding a second copy inside the value is how a
/// bookmark ends up outliving the identity it names — the stored copy goes
/// stale the moment the key it was filed under is rekeyed. Old files still have
/// the field; it decodes as an ignored extra key.
@MemberwiseInit(.public)
public struct RuntimeImageBookmark: Codable, Hashable {
    public let imageNode: RuntimeImageNode
}

/// A bookmarked runtime object, stored under its peer's
/// `RuntimeBookmarkScope`. See ``RuntimeImageBookmark`` for why there is no
/// source field.
@MemberwiseInit(.public)
public struct RuntimeObjectBookmark: Codable, Hashable {
    public let object: RuntimeObject
}
