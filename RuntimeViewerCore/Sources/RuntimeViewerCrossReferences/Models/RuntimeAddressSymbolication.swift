/// What an unslid address is in the process serving the engine: inside which
/// function, a stub and where it leads, a pointer slot and what it holds, a
/// string, the nearest symbol — or nothing an image maps.
///
/// Flat, with one kind and the fields that kind fills, so that `--json` and
/// the MCP response read the same: ``summary`` always says it in words.
public struct RuntimeAddressSymbolication: Hashable, Codable, Sendable {
    public enum Kind: String, Hashable, Codable, Sendable {
        /// Inside a function's body: ``function`` and ``offset``.
        case function
        /// A stub, or a chain of stub islands: ``hops`` and ``target``.
        case stub
        /// A pointer slot: ``slotKind`` and ``target``.
        case pointerSlot
        /// A C string literal: its characters are ``summary``.
        case cString
        /// A constant `CFString` / `NSString`.
        case constantString
        /// None of the above: the nearest symbol at or below it, ``offset``
        /// bytes on.
        case symbol
        /// Mapped by an image, but none of the above, and no symbol at or
        /// below it.
        case data
        /// No image maps it.
        case unmapped
    }

    /// The address asked about, unslid.
    public let address: UInt64
    public let imagePath: String?
    public let segmentName: String?
    public let sectionName: String?
    public let kind: Kind
    /// ``Kind/function``: the function the address lies in.
    public let function: RuntimeFunctionReference?
    /// How far into the function, or past the symbol.
    public let offset: UInt64?
    /// ``Kind/stub``: every trampoline passed through, the address asked
    /// about first.
    public let hops: [UInt64]
    /// Where a stub leads, or what a slot holds — when the wire has a target
    /// for it; an instance variable and a protocol's name are said in
    /// ``summary`` alone.
    public let target: RuntimeCrossReferenceTarget?
    /// ``Kind/pointerSlot``: `globalOffsetTable`, `selectorReference`,
    /// `classReference`, `superclassReference`, `protocolReference` or
    /// `instanceVariableOffset`.
    public let slotKind: String?
    /// What lies there, in words: a function's name and the offset into it,
    /// a string's characters, a symbol, where a stub or a slot leads.
    public let summary: String

    public init(
        address: UInt64,
        imagePath: String?,
        segmentName: String?,
        sectionName: String?,
        kind: Kind,
        function: RuntimeFunctionReference? = nil,
        offset: UInt64? = nil,
        hops: [UInt64] = [],
        target: RuntimeCrossReferenceTarget? = nil,
        slotKind: String? = nil,
        summary: String
    ) {
        self.address = address
        self.imagePath = imagePath
        self.segmentName = segmentName
        self.sectionName = sectionName
        self.kind = kind
        self.function = function
        self.offset = offset
        self.hops = hops
        self.target = target
        self.slotKind = slotKind
        self.summary = summary
    }
}
