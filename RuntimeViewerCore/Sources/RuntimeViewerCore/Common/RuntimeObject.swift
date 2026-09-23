import MetaCodable
import MemberwiseInit
public import SwiftStdlibToolbox

@Codable
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

        /// Marks an Objective-C class whose implementation is written in Swift
        /// as an `@objc @implementation extension` (SE-0436). The compiler
        /// emits such a class as a PURE Objective-C class — the Swift bit of
        /// its class data pointer is clear — so it never gets `isSwiftClass`.
        /// The two are mutually exclusive for that reason, and the badge they
        /// drive is picked in one place:
        /// `RuntimeObjectIcon.secondaryIcon(for:)`.
        public static let isObjCImplementation = Self(rawValue: 1 << 2)

        /// Marks an Objective-C class that is really a Swift class bridged out
        /// to the Objective-C runtime — the Swift bit of its class data
        /// pointer is set (`isSwiftStable`). Mutually exclusive with
        /// `isObjCImplementation`; see that case for why.
        public static let isSwiftClass = Self(rawValue: 1 << 3)
    }

    public let name: String

    /// The name shown to the reader. Deliberately outside identity, because
    /// one type reaches the app under more than one printed name: the sidebar
    /// lists a protocol nested in a type by its own short name while a jump
    /// materializes it under its qualified one, and a link payload the content
    /// pane builds carries the qualified name its tokens spell. Each has to
    /// compare equal to the object it names — so nothing that decides *which*
    /// type this is may read `displayName`; look a type up by `name`.
    public let displayName: String

    public let kind: RuntimeObjectKind

    public let imagePath: String

    /// Deliberately outside identity: `withAppendedChild(_:)` returns the
    /// same type carrying one more child, and a lookup for it has to keep
    /// hitting.
    public let children: [RuntimeObject]

    /// Deliberately outside identity: the same type reaches different call
    /// sites with different marks depending on which path materialized it.
    @Default([])
    @Init(default: [])
    public let properties: Properties

    public var id: RuntimeObjectKey { key }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }

    public func withImagePath(_ imagePath: String) -> RuntimeObject {
        .init(name: name, displayName: displayName, kind: kind, imagePath: imagePath, children: children, properties: properties)
    }

    /// Returns a copy of this object with `child` appended to its `children`.
    /// Used by the sidebar to splice a newly specialized type into the parent
    /// generic without forcing a full data-source rebuild.
    public func withAppendedChild(_ child: RuntimeObject) -> RuntimeObject {
        .init(
            name: name,
            displayName: displayName,
            kind: kind,
            imagePath: imagePath,
            children: children + [child],
            properties: properties,
        )
    }
}

/// Identity is `RuntimeObjectKey` — `(imagePath, name, kind)` — and both
/// operators below are defined through it, so `a == b` and `a.key == b.key`
/// agree by construction rather than by two field lists kept in step.
///
/// `displayName`, `children` and `properties` are excluded on purpose: they
/// differ between two materializations of one type, and every caller that asks
/// `==` is asking "is this the same type", not "is this byte-identical". The
/// question they are not asking has its own method, `hasSameContent(as:)`.
///
/// Hand-written rather than `@Equatable` + `@EquatableIgnored`: that peer macro
/// is also read by `@MemberwiseInit`, which then drops the annotated property
/// from the generated initializer.
extension RuntimeObject {
    public static func == (leftObject: RuntimeObject, rightObject: RuntimeObject) -> Bool {
        leftObject.key == rightObject.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(key)
    }

    /// Whether these two describe the same type in the same state — what `==`
    /// asks, plus the three fields identity leaves out.
    ///
    /// Shallow by design: `children` are compared by identity, one element at a
    /// time, so a child appearing, disappearing or being replaced is visible
    /// while a change buried inside a grandchild is not. That is enough because
    /// the only writer, `SidebarRuntimeObjectViewModel.applySpecializationAdded`,
    /// locates the cell whose direct children are about to change. A writer that
    /// mutates a grandchild without touching its ancestors would need this to
    /// recurse.
    public func hasSameContent(as other: RuntimeObject) -> Bool {
        self == other
            && displayName == other.displayName
            && properties == other.properties
            && children == other.children
    }
}

extension RuntimeObject: ComparableBuildable {
    public static var comparableDefinition: some ComparisonStep<Self> {
        compare(\.imagePath)
        compare(\.kind)
        compare(\.displayName)
    }
}

/// The identity of a `RuntimeObject` — `(imagePath, name, kind)` — as a value
/// of its own; `RuntimeObject`'s `==` and `hash(into:)` are defined through
/// it. Use the key rather than the object as a dictionary or set key: the two
/// compare and hash alike, but an object stored as a key keeps its whole
/// `children` subtree alive for as long as the entry does.
///
/// All stored fingerprint fields are private so the only valid construction
/// path is `RuntimeObjectKey(_:)`; callers can not assemble a key by hand
/// from arbitrary `(imagePath, name, kind)` components and then dereference
/// it back into a `RuntimeObject` that never existed.
public struct RuntimeObjectKey: Hashable, Sendable {
    private let imagePath: String
    private let name: String
    private let kind: RuntimeObjectKind

    public init(_ object: RuntimeObject) {
        self.imagePath = object.imagePath
        self.name = object.name
        self.kind = object.kind
    }
}

extension RuntimeObject {
    public var key: RuntimeObjectKey { RuntimeObjectKey(self) }
}
