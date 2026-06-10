import MetaCodable
import MemberwiseInit
public import SwiftStdlibToolbox

@Codable
@Equatable
@MemberwiseInit(.public)
public struct RuntimeObject: Hashable, Identifiable, Sendable {
    public struct Properties: OptionSet, Codable, Hashable, Sendable {
        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let isGeneric = Self(rawValue: 1 << 0)

        /// Marks a runtime object that was produced by user-driven specialization
        /// of a generic Swift type. The corresponding TypeDefinition carries a
        /// non-nil `metadata` and is rendered with concrete generic arguments
        /// substituted in.
        public static let isSpecialized = Self(rawValue: 1 << 1)
    }

    public let name: String

    public let displayName: String

    public let kind: RuntimeObjectKind

    public let secondaryKind: RuntimeObjectKind?

    public let imagePath: String

    public let children: [RuntimeObject]

    @Default("")
    @Init(default: "")
    public let identityPath: String

    @Default([])
    @Init(default: [])
    public let properties: Properties

    public var id: RuntimeObject { self }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }

    public func withImagePath(_ imagePath: String) -> RuntimeObject {
        .init(name: name, displayName: displayName, kind: kind, secondaryKind: secondaryKind, imagePath: imagePath, children: children, identityPath: identityPath, properties: properties)
    }

    /// Returns a copy of this object with `child` appended to its `children`.
    /// Used by the sidebar to splice a newly specialized type into the parent
    /// generic without forcing a full data-source rebuild.
    public func withAppendedChild(_ child: RuntimeObject) -> RuntimeObject {
        .init(
            name: name,
            displayName: displayName,
            kind: kind,
            secondaryKind: secondaryKind,
            imagePath: imagePath,
            children: children + [child],
            identityPath: identityPath,
            properties: properties,
        )
    }
}

extension RuntimeObject: ComparableBuildable {
    public static var comparableDefinition: some ComparisonStep<Self> {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.displayName)
    }
}

/// Stable identity for a `RuntimeObject` that intentionally excludes
/// `RuntimeObject.children`. Use this as a dictionary / set key when
/// lookups must survive `parent.withAppendedChild(child)` replacements — the
/// underlying type is unchanged across that operation but `RuntimeObject ==`
/// would otherwise flip false because `children` participates in identity.
///
/// All stored fingerprint fields are private so the only valid construction
/// path is `RuntimeObjectKey(_:)`; callers can not assemble a key by hand
/// from arbitrary `(imagePath, name, kind)` components and then dereference
/// it back into a `RuntimeObject` that never existed.
public struct RuntimeObjectKey: Hashable, Sendable {
    private let imagePath: String
    private let name: String
    private let kind: RuntimeObjectKind
    private let identityPath: String

    public init(_ object: RuntimeObject) {
        self.imagePath = object.imagePath
        self.name = object.name
        self.kind = object.kind
        self.identityPath = object.identityPath
    }
}

extension RuntimeObject {
    public var key: RuntimeObjectKey { RuntimeObjectKey(self) }
}
