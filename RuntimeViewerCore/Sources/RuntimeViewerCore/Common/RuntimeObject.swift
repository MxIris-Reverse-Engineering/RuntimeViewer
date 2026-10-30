import MetaCodable
import MemberwiseInit
public import SwiftStdlibToolbox

@Codable
@MemberwiseInit(.public)
public struct RuntimeObject: Hashable, Identifiable, Sendable {
    public struct Properties: OptionSet, Codable, Hashable, Sendable {
        /// Every flag, one case each, named after its static below; the raw
        /// value is the position of the flag's bit. The bits are wire format —
        /// `properties` encodes as its raw value, and engines of other builds
        /// read it — so a case never changes its raw value and a retired one
        /// is never reused. A new flag is a new case with the next position,
        /// and its static is built from that case, never from
        /// `init(rawValue:)` directly.
        ///
        /// Every flag is also something the sidebar's Filter Scope can filter
        /// by: `RuntimeObjectScope.Property.rows(filtering:)` in
        /// RuntimeViewerApplication switches over this enum exhaustively, so a
        /// new case does not build until the Filter Scope has a row for it.
        public enum Flag: Int, CaseIterable, Sendable {
            case isGeneric = 0
            case isSpecialized = 1
            case isObjCImplementation = 2
            case isSwiftClass = 3
            case isObjCClass = 4
            case isLocalType = 5
            case isPositionNamedLocalType = 6
            case isSwiftProtocol = 7
            case isObjCProtocol = 8
            case isNotExported = 9
        }

        public let rawValue: Int

        public init(rawValue: Int) { self.rawValue = rawValue }

        public init(_ flag: Flag) { self.init(rawValue: 1 << flag.rawValue) }

        public static let isGeneric = Self(.isGeneric)

        /// Marks a runtime object that was produced by user-driven specialization
        /// of a generic Swift type. The corresponding TypeDefinition carries a
        /// non-nil `metadata` and is rendered with concrete generic arguments
        /// substituted in.
        public static let isSpecialized = Self(.isSpecialized)

        /// Marks both faces of a class implemented through an
        /// `@objc @implementation extension` (SE-0436): the Objective-C class,
        /// and the Swift `extension` carrying its bodies. The compiler emits
        /// such a class as a PURE Objective-C class — the Swift bit of its
        /// class data pointer is clear — so it never gets `isSwiftClass`. The
        /// two are mutually exclusive for that reason, and the badge they
        /// drive is picked in one place:
        /// `RuntimeObjectIcon.secondaryIcon(for:)`.
        public static let isObjCImplementation = Self(.isObjCImplementation)

        /// Marks an Objective-C class that is really a Swift class bridged out
        /// to the Objective-C runtime — the Swift bit of its class data
        /// pointer is set (`isSwiftStable`). Mutually exclusive with
        /// `isObjCImplementation`; see that case for why.
        public static let isSwiftClass = Self(.isSwiftClass)

        /// The Swift face of `isSwiftClass`: a Swift class whose class object
        /// its image registers with the Objective-C runtime, so the Objective-C
        /// class list carries it too. Generic and specialized classes have no
        /// static class object and never get it.
        public static let isObjCClass = Self(.isObjCClass)

        /// Marks a Swift type declared in a function or closure body. Its
        /// `displayName` is the name a reader is shown of it,
        /// `Visitor #1 in TableDataSource.performDrop(to:)`. A type nested in
        /// a local type is not one itself.
        public static let isLocalType = Self(.isLocalType)

        /// Marks an `isLocalType` type whose function or closure the binary
        /// does not name, so it is named by the address of the anonymous
        /// context wrapping it: `TableDataSource.(Visitor in $1a2b3c)`.
        public static let isPositionNamedLocalType = Self(.isPositionNamedLocalType)

        /// Marks an Objective-C protocol that was defined in Swift — possibly
        /// in another module, since a Swift image that only uses a protocol
        /// carries a copy of its record too. The protocol counterpart of
        /// `isSwiftClass`: the Swift list shows the protocol as well, in the
        /// image that declares it, which for such a copy is another image.
        /// How a protocol is recognized, and the one kind it misses:
        /// `SwiftDefinedObjCProtocols`.
        public static let isSwiftProtocol = Self(.isSwiftProtocol)

        /// The Swift face of `isSwiftProtocol`: an `@objc` protocol this image
        /// declares in Swift, whose declaration MachOSwiftSection paired with
        /// the image's Objective-C record of it, so the Objective-C protocol
        /// list carries it too. One renamed with `@objc(Name)` to a name other
        /// than its Swift name pairs with no record and never gets it.
        public static let isObjCProtocol = Self(.isObjCProtocol)

        /// Marks a Swift type or protocol whose image provably does not export
        /// it: MachOSwiftSection rules the descriptor symbol out of the image's
        /// export trie (`ExportStatus.isDefinitelyNotExported`). Its members
        /// and nested types are then not exported either. Only that verdict
        /// sets it — never a guess — so an object without it may be exported
        /// or merely unjudged: an image without export information, an `@objc`
        /// protocol declared in Swift, a type imported from C, and every
        /// extension and conformance entry. A specialized type takes the
        /// value of the generic type it specializes. Engines of builds from
        /// before this flag never set it.
        public static let isNotExported = Self(.isNotExported)
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

    /// The `private` and `fileprivate` declarations a Swift name runs through, in the order the
    /// name reads them, each once — read off the `privateDeclName` nodes of the demangled name.
    /// `displayName` is printed without their discriminators, so this is where they are kept.
    /// Empty for every other object.
    @Default([])
    @Init(default: [])
    public let privateDeclarations: [RuntimePrivateDeclaration]

    public var id: RuntimeObjectKey { key }

    public var imageName: String { imagePath.lastPathComponent.deletingPathExtension }

    public func withImagePath(_ imagePath: String) -> RuntimeObject {
        .init(name: name, displayName: displayName, kind: kind, imagePath: imagePath, children: children, properties: properties, privateDeclarations: privateDeclarations)
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
            privateDeclarations: privateDeclarations,
        )
    }
}

/// Identity is `RuntimeObjectKey` — `(imagePath, name, kind)` — and both
/// operators below are defined through it, so `a == b` and `a.key == b.key`
/// agree by construction rather than by two field lists kept in step.
///
/// `displayName`, `children`, `properties` and `privateDeclarations` are
/// excluded on purpose: they can differ between two materializations of one
/// type, and every caller that asks
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
    /// asks, plus the four fields identity leaves out.
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
            && privateDeclarations == other.privateDeclarations
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
