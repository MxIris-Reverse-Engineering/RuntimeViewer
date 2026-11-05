import Foundation
public import RuntimeViewerCore

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
