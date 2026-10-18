// `public import` because these types cross the public API, and this module
// builds with `InternalImportsByDefault`.
public import Foundation
public import RuntimeViewerCore

// The wire types of the cross-reference commands. Every one is `Codable`:
// a query crosses from the host to whatever process serves the engine, and the
// answer comes back the same way.

/// A member of a runtime object, as a cross reference points at it.
public struct RuntimeMemberReference: Hashable, Codable, Sendable {
    public let object: RuntimeObject
    public let name: String
    public let kind: RuntimeMemberKind
    public let isStatic: Bool

    public init(object: RuntimeObject, name: String, kind: RuntimeMemberKind, isStatic: Bool) {
        self.object = object
        self.name = name
        self.kind = kind
        self.isStatic = isStatic
    }
}

/// A function the analysis scanned, named or not.
///
/// Half the functions in a dyld shared cache carry no symbol; they are
/// functions all the same, with `displayName` and `symbolName` both `nil`, and
/// a front end shows them by address and image.
public struct RuntimeFunctionReference: Hashable, Codable, Sendable {
    public let imagePath: String
    /// The unslid address of the first instruction — what `dyld_info` and a
    /// disassembler print.
    public let address: UInt64
    /// As Runtime Viewer prints it: `-[NSWindow makeKeyAndOrderFront:]`,
    /// `SwiftUI.ViewGraph.updateOutputs(at:)`, `CFRelease`; `nil` when neither a
    /// symbol nor metadata names the function.
    public let displayName: String?
    /// The symbol the name came from, as the symbol table spells it:
    /// `_CFRelease`, `_$s7SwiftUI9ViewGraphC…`, `-[NSWindow makeKeyAndOrderFront:]`.
    public let symbolName: String?
    /// The member this function implements, when it maps to one.
    public let member: RuntimeMemberReference?
    /// Other symbols sharing this address because the linker folded
    /// identical code.
    public let foldedSymbolCount: Int

    public init(imagePath: String, address: UInt64, displayName: String?, symbolName: String?, member: RuntimeMemberReference?, foldedSymbolCount: Int) {
        self.imagePath = imagePath
        self.address = address
        self.displayName = displayName
        self.symbolName = symbolName
        self.member = member
        self.foldedSymbolCount = foldedSymbolCount
    }
}

public enum RuntimeCrossReferenceKind: String, Hashable, Codable, Sendable {
    case call
    case tailCall
    case messageSend
    case superMessageSend
    case typeReference
    case indirectCall
}

public enum RuntimeCrossReferencePrecision: String, Hashable, Codable, Sendable {
    /// The instruction names its target.
    case exact
    /// An Objective-C send whose receiver's class is not known: every send of
    /// the selector matches.
    case matchedBySelector
    /// One of several targets an indirect call may reach.
    case candidate
}

public enum RuntimeCrossReferenceTarget: Hashable, Codable, Sendable {
    /// A function, named or not. A branch into the middle of a function is a
    /// function reference at that address with no name.
    case function(RuntimeFunctionReference)
    /// A stub whose slot could not be followed, by the name it imports, as
    /// the symbol table spells it.
    case importedSymbol(name: String)
    /// A message, and the receiver's class when the analysis knows it.
    case selector(name: String, receiverClassName: String?)
    /// A type: as Runtime Viewer prints it, and the object it is when the
    /// query knows it — a type references query always does.
    case type(name: String, object: RuntimeObject?)
    /// A call through a register, with the evidence the instruction gives.
    case indirect(tableOffset: Int64?, pointerAuthenticationConstant: UInt16?)
    /// A branch to code no image and no recognized trampoline holds — or data
    /// in `__text` that decoded as a branch. The address is unslid, in the
    /// referencing function's image.
    case unrecognizedCode(address: UInt64)
}

/// One instruction's reference.
public struct RuntimeCrossReference: Hashable, Codable, Sendable {
    /// The function the referencing instruction belongs to.
    public let referencingFunction: RuntimeFunctionReference
    /// The referencing instruction's unslid address, in the same image as
    /// ``referencingFunction``.
    public let instructionAddress: UInt64
    public let kind: RuntimeCrossReferenceKind
    public let target: RuntimeCrossReferenceTarget
    public let precision: RuntimeCrossReferencePrecision
    /// A retain or release, an outlined value operation, or another runtime
    /// helper.
    public let isRuntimeHelperCall: Bool

    public init(referencingFunction: RuntimeFunctionReference, instructionAddress: UInt64, kind: RuntimeCrossReferenceKind, target: RuntimeCrossReferenceTarget, precision: RuntimeCrossReferencePrecision, isRuntimeHelperCall: Bool) {
        self.referencingFunction = referencingFunction
        self.instructionAddress = instructionAddress
        self.kind = kind
        self.target = target
        self.precision = precision
        self.isRuntimeHelperCall = isRuntimeHelperCall
    }
}

/// What a query asks about.
public enum RuntimeCrossReferenceSubject: Hashable, Codable, Sendable {
    /// The function holding an unslid address in an image.
    case function(imagePath: String, address: UInt64)
    case member(RuntimeMemberReference)
    /// Every send of this selector, whatever the receiver. Has callers, no
    /// callees.
    case selector(String)
}

/// The images a query reads. Only images the engine has indexed — both their
/// Objective-C and their Swift section built: the ones opened in the sidebar
/// and the ones background indexing read — are ever scanned.
public enum RuntimeCrossReferenceScope: Hashable, Codable, Sendable {
    /// One image, which the engine must have indexed.
    case image(path: String)
    /// Every image the engine has indexed.
    case indexedImages
}

public struct RuntimeCrossReferenceQueryOptions: Hashable, Codable, Sendable {
    /// Keep calls to retains, releases, outlined value operations and other
    /// runtime helpers among the callees. Callers are never filtered: a query
    /// for a helper's callers asks for exactly those.
    public var includesRuntimeHelperCalls: Bool
    /// Keep only sends whose receiver is known to be this class, or is
    /// unknown. References that are not sends are kept.
    public var receiverClassName: String?
    /// Stop after this many references; the result is then incomplete. A scan
    /// across images stops as soon as it has them, so which ones come back
    /// depends on which images finished first.
    public var resultLimit: Int?
    /// How many images the engine's process scans at the same time, each
    /// keeping a core busy, across every query it runs. The process keeps the
    /// count the latest query brought; `nil` leaves it as it is — four, until
    /// a query sets another. The app sends its Max Concurrent Scans setting.
    public var maximumConcurrentScans: Int?

    public init(includesRuntimeHelperCalls: Bool = false, receiverClassName: String? = nil, resultLimit: Int? = nil, maximumConcurrentScans: Int? = nil) {
        self.includesRuntimeHelperCalls = includesRuntimeHelperCalls
        self.receiverClassName = receiverClassName
        self.resultLimit = resultLimit
        self.maximumConcurrentScans = maximumConcurrentScans
    }
}

/// How far a scan across images has come, with what it found since the last
/// report — so a caller that gives up early still has those. Over a whole
/// query the reports carry exactly the references of the result.
public struct RuntimeCrossReferenceQueryProgress: Hashable, Codable, Sendable {
    public let scannedImageCount: Int
    public let totalImageCount: Int
    public let references: [RuntimeCrossReference]

    public init(scannedImageCount: Int, totalImageCount: Int, references: [RuntimeCrossReference]) {
        self.scannedImageCount = scannedImageCount
        self.totalImageCount = totalImageCount
        self.references = references
    }
}

public struct RuntimeCrossReferenceQueryResult: Hashable, Codable, Sendable {
    /// Callers in image order, then by instruction address; callees in
    /// instruction order.
    public let references: [RuntimeCrossReference]
    /// `false` when ``RuntimeCrossReferenceQueryOptions/resultLimit`` cut the
    /// query short.
    public let isComplete: Bool

    public init(references: [RuntimeCrossReference], isComplete: Bool) {
        self.references = references
        self.isComplete = isComplete
    }
}

public enum RuntimeCrossReferenceError: Error, LocalizedError, Sendable, Equatable {
    /// The process serving the engine does not run arm64 code.
    case unsupportedArchitecture
    case imageNotFound(path: String)
    /// The scope names an image the engine has not indexed, whose code a
    /// query does not read.
    case imageNotIndexed(path: String)
    case functionNotFound(imagePath: String, address: UInt64)
    case memberNotFound(objectName: String, memberName: String)
    /// A selector is a message, not code: it has senders but no callees.
    case selectorHasNoCallees(String)
    /// Type references are found for Objective-C classes and for Swift
    /// structs, enums and classes; the object is none of these, or its image
    /// does not define it.
    case typeNotFound(objectName: String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedArchitecture:
            "Cross references read arm64 and arm64e machine code; the process serving this engine runs neither."
        case .imageNotFound(let path):
            "No image at \(path) is loaded or in the shared cache of the process serving this engine."
        case .imageNotIndexed(let path):
            "\((path as NSString).lastPathComponent) is not indexed. Cross references read indexed images only: load it first."
        case .functionNotFound(let imagePath, let address):
            "No function holds 0x\(String(address, radix: 16)) in \(imagePath)."
        case .memberNotFound(let objectName, let memberName):
            "\(objectName) has no member \(memberName) with code — or its image is not loaded in the engine."
        case .selectorHasNoCallees(let selector):
            "\(selector) is a selector: it has senders, but no code of its own to call anything."
        case .typeNotFound(let objectName):
            "\(objectName) is not an Objective-C class or a Swift struct, enum or class its image defines, so its references cannot be found."
        }
    }
}
