import Foundation

/// The kind of process that can load an image of the dyld shared cache.
///
/// dyld lets a Mac Catalyst process — and an iOS app running on a Mac — load
/// an image built for macOS, but never lets a macOS process load one built for
/// Mac Catalyst alone (`Header::loadableIntoProcess` in dyld). So each image of
/// this Mac's shared cache is either one a macOS process loads, or one only a
/// Mac Catalyst process does, and the two engines that keep the cache's data —
/// My Mac and My Mac (Mac Catalyst) — split it along this line. A path prefix
/// does not: `/System/iOSSupport` holds a macOS image or two, and a few images
/// built for Mac Catalyst alone live outside it.
public enum RuntimeSharedCacheImagePlatform: Sendable, Hashable {
    /// Built for macOS, alone or zippered with Mac Catalyst: a macOS process
    /// loads it.
    case macOS

    /// Built for Mac Catalyst only: only a Mac Catalyst process loads it.
    case macCatalyst
}
