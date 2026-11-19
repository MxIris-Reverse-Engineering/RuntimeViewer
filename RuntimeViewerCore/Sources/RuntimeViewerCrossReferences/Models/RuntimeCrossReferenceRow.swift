public import Foundation

/// One reference as the command line's `--json` and the MCP tools report it:
/// flat, every address a hexadecimal string — a client reading JSON numbers as
/// doubles loses the low bits of a 64-bit address.
///
/// The one place these field names are spelled: the command line encodes
/// this type, and the MCP response copies it field for field
/// (`MCPCrossReferenceInfo`), with a test holding the two to the same keys.
public struct RuntimeCrossReferenceRow: Hashable, Codable, Sendable {
    /// The image of the referencing function.
    public let imagePath: String
    /// Its file name without extension.
    public let imageName: String
    /// The referencing function's first instruction, unslid.
    public let functionAddress: String
    /// As Runtime Viewer prints it, when anything names the function.
    public let functionName: String?
    /// The symbol the name came from.
    public let functionSymbol: String?
    /// The referencing instruction, unslid.
    public let instructionAddress: String
    /// `call`, `tailCall`, `messageSend`, `superMessageSend`, `typeReference`
    /// or `indirectCall`.
    public let kind: String
    /// `function`, `importedSymbol`, `selector`, `type`, `indirect` or
    /// `unrecognizedCode`.
    public let targetKind: String
    /// What is referenced, in words: a function's name and image, a symbol,
    /// a selector and its receiver's class, a type, an indirect call's
    /// evidence, an address.
    public let target: String
    /// `exact`, `matchedBySelector` or `candidate`.
    public let precision: String
    public let isRuntimeHelperCall: Bool

    public init(_ reference: RuntimeCrossReference) {
        let function = reference.referencingFunction
        self.imagePath = function.imagePath
        self.imageName = Self.imageName(ofPath: function.imagePath)
        self.functionAddress = Self.hexadecimal(function.address)
        self.functionName = function.displayName
        self.functionSymbol = function.symbolName
        self.instructionAddress = Self.hexadecimal(reference.instructionAddress)
        self.kind = reference.kind.rawValue
        self.precision = reference.precision.rawValue
        self.isRuntimeHelperCall = reference.isRuntimeHelperCall
        switch reference.target {
        case .function(let target):
            self.targetKind = "function"
            self.target = (target.displayName ?? target.symbolName ?? Self.hexadecimal(target.address)) + " (\(Self.imageName(ofPath: target.imagePath)))"
        case .importedSymbol(let name):
            self.targetKind = "importedSymbol"
            self.target = name
        case .selector(let name, let receiverClassName):
            self.targetKind = "selector"
            self.target = receiverClassName.map { "\(name) to \($0)" } ?? name
        case .type(let name, _):
            self.targetKind = "type"
            self.target = name
        case .indirect(let tableOffset, let pointerAuthenticationConstant):
            self.targetKind = "indirect"
            self.target = [
                tableOffset.map { "offset \($0)" },
                pointerAuthenticationConstant.map { "discriminator 0x\(String($0, radix: 16))" },
            ].compactMap { $0 }.joined(separator: ", ")
        case .unrecognizedCode(let address):
            self.targetKind = "unrecognizedCode"
            self.target = Self.hexadecimal(address)
        }
    }

    static func hexadecimal(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    static func imageName(ofPath path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
