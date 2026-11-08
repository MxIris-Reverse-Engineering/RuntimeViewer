import Foundation

/// The engines that keep the data of this Mac's shared cache images, and the
/// partition that says which one keeps which image.
///
/// My Mac keeps every image a macOS process can load, My Mac (Mac Catalyst)
/// the images built for Mac Catalyst alone. An engine given owners — either of
/// the two, or a process attached on this Mac that maps the same cache —
/// hands every request about one of these images to its owner and answers
/// only for its own images, so each shared cache image is indexed, printed
/// and scanned once, in one process, however many engines show it. Only the
/// engine manager gives an engine owners: `RuntimeEngine` never learns where
/// an owner runs or how it is reached.
public struct RuntimeSharedCacheOwners: Sendable {
    public let partition: RuntimeSharedCachePartition

    /// The owner of every image a macOS process can load.
    public let macOS: RuntimeEngine

    /// The owner of the images built for Mac Catalyst alone; `nil` while the
    /// Mac Catalyst engine is not up, which leaves those images with
    /// whichever engine is asked about them.
    public let macCatalyst: RuntimeEngine?

    public init(partition: RuntimeSharedCachePartition, macOS: RuntimeEngine, macCatalyst: RuntimeEngine?) {
        self.partition = partition
        self.macOS = macOS
        self.macCatalyst = macCatalyst
    }

    /// The engine that keeps the data of the image at `imagePath`, or `nil`
    /// when no owner keeps it: an image outside the cache, or a Mac Catalyst
    /// image while the Mac Catalyst engine is not up.
    public func owner(ofImageAt imagePath: String) -> RuntimeEngine? {
        switch partition.platform(ofImageAt: imagePath) {
        case .macOS:
            macOS
        case .macCatalyst:
            macCatalyst
        case nil:
            nil
        }
    }

    /// The owners as distinct engines, My Mac first.
    public var engines: [RuntimeEngine] {
        guard let macCatalyst, macCatalyst !== macOS else { return [macOS] }
        return [macOS, macCatalyst]
    }
}

extension RuntimeSharedCacheOwners: Equatable {
    /// The same partition and the same owner engines, by identity.
    public static func == (leftOwners: RuntimeSharedCacheOwners, rightOwners: RuntimeSharedCacheOwners) -> Bool {
        leftOwners.partition === rightOwners.partition
            && leftOwners.macOS === rightOwners.macOS
            && leftOwners.macCatalyst === rightOwners.macCatalyst
    }
}
