import Foundation
import Semantic
import ObjCDump
import ObjCTypeDecodeKit
import MemberwiseInit

@MemberwiseInit()
final class ObjCDumpContext {
    var options: ObjCGenerationOptions
    var currentArray: SemanticString?
    var isExpandHandler: (_ name: String?, _ isStruct: Bool) -> Bool = { _, _ in true }
}

extension ObjCClassInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        Keyword("@interface")
        Space()
        TypeDeclaration(kind: .class, name)

        if let superClassName {
            " : "
            TypeName(kind: .class, superClassName)
        }

        Joined(separator: ", ", prefix: " <", suffix: ">") {
            for `protocol` in protocols {
                TypeName(kind: .protocol, `protocol`.name)
            }
        }

        Joined {
            MemberList(level: 1) {
                for ivar in ivars {
                    ivar.semanticString(using: context)
                }
            }
        } prefix: {
            Space()
            "{"
        } suffix: {
            "}"
        }

        BreakLine()

        Joined(suffix: BreakLine()) {
            BlockList {
                for property in classProperties {
                    property.semanticString(using: context)
                }
            }
            BlockList {
                for property in properties {
                    property.semanticString(using: context)
                }
            }
            BlockList {
                for method in classMethods {
                    method.semanticString(using: context)
                }
            }
            BlockList {
                for method in methods {
                    method.semanticString(using: context)
                }
            }
        }

        Keyword("@end")
    }
}

extension ObjCProtocolInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        Keyword("@protocol")
        Space()
        TypeDeclaration(kind: .protocol, name)

        Joined(separator: ", ", prefix: " <", suffix: ">") {
            for `protocol` in protocols {
                TypeName(kind: .protocol, `protocol`.name)
            }
        }

        BreakLine()

        Joined(separator: BreakLine(), prefix: BreakLine(), suffix: BreakLine()) {
            Joined {
                BlockList {
                    for property in classProperties {
                        property.semanticString(using: context)
                    }
                }
                BlockList {
                    for property in properties {
                        property.semanticString(using: context)
                    }
                }
                BlockList {
                    for method in classMethods {
                        method.semanticString(using: context)
                    }
                }
                BlockList {
                    for method in methods {
                        method.semanticString(using: context)
                    }
                }
            } prefix: {
                Keyword("@required")
                BreakLine()
            }

            Joined {
                BlockList {
                    for property in optionalClassProperties {
                        property.semanticString(using: context)
                    }
                }
                BlockList {
                    for property in optionalProperties {
                        property.semanticString(using: context)
                    }
                }
                BlockList {
                    for method in optionalClassMethods {
                        method.semanticString(using: context)
                    }
                }
                BlockList {
                    for method in optionalMethods {
                        method.semanticString(using: context)
                    }
                }
            } prefix: {
                Keyword("@optional")
                BreakLine()
            }
        }

        Keyword("@end")
    }
}

extension ObjCCategoryInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        Keyword("@interface")
        Space()
        TypeName(kind: .class, className)
        Space()
        "(\(name))"

        Joined(separator: ", ", prefix: " <", suffix: ">") {
            for `protocol` in protocols {
                TypeName(kind: .protocol, `protocol`.name)
            }
        }

        BreakLine()

        Joined(suffix: BreakLine()) {
            BlockList {
                for property in classProperties {
                    property.semanticString(using: context)
                }
            }

            BlockList {
                for property in properties {
                    property.semanticString(using: context)
                }
            }

            BlockList {
                for method in classMethods {
                    method.semanticString(using: context)
                }
            }

            BlockList {
                for method in methods {
                    method.semanticString(using: context)
                }
            }
        }

        Keyword("@end")
    }
}

extension ObjCIvarInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        if let type, case .bitField(let width) = type {
            ObjCField(type: .int, name: name, bitWidth: width)
                .semanticString(fallbackName: name, context: context)
        } else {
            if [.char, .uchar].contains(type) {
                Keyword("BOOL")
                Space()
                Variable(name)
                ";"
            } else {
                if let type = type?.semanticDecoded(context: context) {
                    type
                    if type.string.last != "*" {
                        Space()
                    }
                    Variable(name)
                    if let currentArray = context.currentArray {
                        currentArray
                        context.currentArray = nil
                    }
                    ";"
                } else {
                    UnknownError()
                    Space()
                    Variable(name)
                    ";"
                }
            }
        }

        if context.options.addIvarOffsetComments {
            Space()
            Comment("offset: \(offset)")
        }
    }
}

extension ObjCPropertyInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        Keyword("@property")

        Joined(separator: ", ", prefix: " (", suffix: ")") {
            if attributes.contains(.nonatomic) {
                Keyword("nonatomic")
            }

            if attributes.contains(.weak) {
                Keyword("weak")
            }

            if attributes.contains(.copy) {
                Keyword("copy")
            }

            if attributes.contains(.retain) {
                Keyword("strong")
            }

            if isClassProperty {
                Keyword("class")
            }

            if let getter = attributes.compactMap(\.getter).first {
                Group {
                    Keyword("getter")
                    "="
                    getter
                }
            }

            if let setter = attributes.compactMap(\.setter).first {
                Group {
                    Keyword("setter")
                    "="
                    setter
                }
            }

            if attributes.contains(.readonly) {
                Keyword("readonly")
            }
        }

        Space()

        let typeString = attributes.compactMap(\.type).first?.semanticDecodedForArgument(context: context)

        if let typeString {
            typeString
        } else {
            UnknownError()
        }

        if !(typeString?.string.last == "*" || typeString == nil) {
            Space()
        }

        MemberDeclaration(name)
        ";"

        if context.options.addPropertyAttributesComments {
            Joined(separator: " ", prefix: " ") {
                if attributes.contains(.dynamic) {
                    Comment("@dynamic \(name)")
                }

                if let ivar {
                    if ivar == name {
                        Comment("@synthesize \(ivar)")
                    } else {
                        Comment("@synthesize \(name) = \(ivar)")
                    }
                }
            }
        }
    }
}

extension ObjCMethodInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        if isClassMethod {
            "+"
        } else {
            "-"
        }

        Space()

        "("
        if let returnType = type?.returnType {
            returnType.semanticDecodedForArgument(context: context)
        } else {
            UnknownError()
        }
        ")"

        let numberOfArguments = name.filter { $0 == ":" }.count

        if numberOfArguments == 0 {
            FunctionDeclaration(name)
        } else {
            let nameAndLabels = name.split(separator: ":")
            let argumentInfos = type?.argumentInfos ?? []

            for (index, label) in nameAndLabels.enumerated() {
                if index > 0 {
                    Space()
                }
                let labelString = String(label)
                FunctionDeclaration(labelString)
                ":"
                "("
                if index < argumentInfos.count {
                    argumentInfos[index].type.semanticDecodedForArgument(context: context)
                } else {
                    Error("unknown")
                }
                ")"
                Argument(NamingIntelligent.parameterName(from: labelString))
            }
        }

        ";"
    }
}

extension ObjCField {
    @SemanticStringBuilder
    func semanticString(fallbackName: String, level: Int = 1, context: ObjCDumpContext) -> SemanticString {
        type.semanticDecoded(level: level, context: context)
        Space()
        Variable(name ?? fallbackName)
        if let bitWidth {
            " : "
            Numeric(bitWidth)
        }
        ";"
    }
}

extension ObjCModifier {
    @SemanticStringBuilder
    func semanticDecoded(level: Int = 1) -> SemanticString {
        switch self {
        case .complex:
            Keyword("_Complex")
        case .atomic:
            Keyword("_Atomic")
        case .const:
            Keyword("const")
        case .in:
            Keyword("in")
        case .inout:
            Keyword("inout")
        case .out:
            Keyword("out")
        case .bycopy:
            Keyword("bycopy")
        case .byref:
            Keyword("byref")
        case .oneway:
            Keyword("oneway")
        case .register:
            Keyword("register")
        }
    }
}

extension ObjCType {
    @SemanticStringBuilder
    func semanticDecodedForArgument(context: ObjCDumpContext) -> SemanticString {
        switch self {
        case .struct(let name, let fields),
             .union(let name, let fields):
            Keyword(isStruct ? "struct" : "union")
            if let name {
                Space()
                TypeName(kind: isStruct ? .struct : .other, name)
            }

            if context.isExpandHandler(name, isStruct) {
                Joined {
                    if let fields {
                        Joined(separator: " ") {
                            for (index, field) in fields.enumerated() {
                                Group {
                                    field.type.semanticDecodedForArgument(context: context)
                                    Space()
                                    Variable(field.name ?? "x\(index)")
                                    if let bitWidth = field.bitWidth {
                                        " : "
                                        Numeric(bitWidth)
                                    }
                                    ";"
                                }
                            }
                        }
                    }
                } prefix: {
                    " { "
                } suffix: {
                    " }"
                }
            }
        case .char:
            Keyword("BOOL")
        case .pointer(let type):
            type.semanticDecodedForArgument(context: context)
            Space()
            "*"
        case .modified(let modifier, let type):
            modifier.semanticDecoded(level: 0)
            Space()
            type.semanticDecodedForArgument(context: context)
        default:
            semanticDecoded(level: 0, context: context)
        }
    }

    @SemanticStringBuilder
    func semanticDecoded(level: Int = 1, context: ObjCDumpContext) -> SemanticString {
        switch self {
        case .class:
            TypeName(kind: .class, "Class")
        case .selector:
            Keyword("SEL")
        case .char:
            Keyword("char")
        case .uchar:
            Joined(separator: Space()) {
                Keyword("unsigned")
                Keyword("char")
            }
        case .short:
            Keyword("short")
        case .ushort:
            Joined(separator: Space()) {
                Keyword("unsigned")
                Keyword("short")
            }
        case .int:
            Keyword("int")
        case .uint:
            Joined(separator: Space()) {
                Keyword("unsigned")
                Keyword("int")
            }
        case .long:
            Keyword("long")
        case .ulong:
            Joined(separator: Space()) {
                Keyword("unsigned")
                Keyword("long")
            }
        case .longLong:
            Joined(separator: Space()) {
                Keyword("long")
                Keyword("long")
            }
        case .ulongLong:
            Joined(separator: Space()) {
                Keyword("unsigned")
                Keyword("long")
                Keyword("long")
            }
        case .int128:
            TypeName(kind: .other, "__int128_t")
        case .uint128:
            TypeName(kind: .other, "__uint128_t")
        case .float:
            Keyword("float")
        case .double:
            Keyword("double")
        case .longDouble:
            Joined(separator: Space()) {
                Keyword("long")
                Keyword("double")
            }
        case .bool:
            Keyword("BOOL")
        case .void:
            Keyword("void")
        case .unknown:
            UnknownError()
        case .charPtr:
            Keyword("char")
            Space()
            "*"
        case .atom:
            Keyword("atom")
        case .object(let name):
            if let name {
                if name.first == "<" && name.last == ">" {
                    let components = name.components(separatedBy: "><")
                    Keyword("id")
                    if components.count > 1 {
                        Joined(separator: ", ", prefix: "<", suffix: ">") {
                            for (offset, component) in components.offsetEnumerated() {
                                if offset.isStart {
                                    TypeName(kind: .protocol, String(component.dropFirst(1)))
                                } else if offset.isEnd {
                                    TypeName(kind: .protocol, String(component.dropLast(1)))
                                } else {
                                    TypeName(kind: .protocol, String(component))
                                }
                            }
                        }
                    } else {
                        "<"
                        TypeName(kind: .protocol, String(name.dropFirst(1).dropLast(1)))
                        ">"
                    }
                } else {
                    if let protocolPrefixIndex = name.firstIndex(where: { $0 == "<" }) {
                        let protocols = name[protocolPrefixIndex..<name.endIndex]
                        let components = protocols.components(separatedBy: "><")
                        TypeName(kind: .class, String(name[name.startIndex..<protocolPrefixIndex]))
                        if components.count > 1 {
                            Joined(separator: ", ", prefix: "<", suffix: ">") {
                                for (offset, component) in components.offsetEnumerated() {
                                    if offset.isStart {
                                        TypeName(kind: .protocol, String(component.dropFirst(1)))
                                    } else if offset.isEnd {
                                        TypeName(kind: .protocol, String(component.dropLast(1)))
                                    } else {
                                        TypeName(kind: .protocol, String(component))
                                    }
                                }
                            }
                        } else {
                            "<"
                            TypeName(kind: .protocol, String(name.dropFirst(1).dropLast(1)))
                            ">"
                        }
                        Space()
                        "*"
                    } else {
                        TypeName(kind: .class, name)
                        Space()
                        "*"
                    }
                }
            } else {
                Keyword("id")
            }
        case .block(let ret, let args):
            if let ret, let args {
                ret.semanticDecoded(level: level, context: context)
                " (^)("
                Joined(separator: ", ") {
                    for arg in args {
                        arg.semanticDecoded(level: level, context: context)
                    }
                }
                ")"
            } else {
                Keyword("id")
                Space()
                InlineComment("block")
            }
        case .functionPointer:
            Keyword("void")
            Space()
            "*"
            Space()
            InlineComment("function pointer")
        case .array(let type, let size):
            type.semanticDecoded(level: level, context: context)
            context.currentArray = SemanticString {
                "["
                if let size {
                    Numeric(size)
                }
                "]"
            }
        case .pointer(let type):
            type.semanticDecoded(level: level, context: context)
            Space()
            "*"
        case .bitField(let width):
            Keyword("int")
            Space()
            Variable("x")
            " : "
            Numeric(width)
        case .struct(let name, let fields),
             .union(let name, let fields):
            Keyword(isStruct ? "struct" : "union")
            if let name {
                Space()
                TypeName(kind: isStruct ? .struct : .other, name)
            }
            if context.isExpandHandler(name, false) {
                Joined {
                    if let fields {
                        MemberList(level: level + 1) {
                            for (index, field) in fields.enumerated() {
                                field.semanticString(fallbackName: "x\(index)", level: level + 1, context: context)
                            }
                        }
                    }
                } prefix: {
                    " {"
                } suffix: {
                    Indent(level: level)
                    "}"
                }.if(fields != nil || name == nil)
            }
        case .modified(let modifier, let type):
            modifier.semanticDecoded(level: level)
            Space()
            type.semanticDecoded(level: level, context: context)
        case .other(let string):
            string
        }
    }
}

extension ObjCCategoryInfo {
    var uniqueName: String {
        "\(className)(\(name))"
    }
}

extension ObjCPropertyInfo {
    var ivar: String? {
        attributes.compactMap(\.ivar).first
    }

    var customGetter: String? {
        attributes.compactMap(\.getter).first
    }

    var customSetter: String? {
        attributes.compactMap(\.setter).first
    }
}

// MARK: - Naming Intelligent

/// A utility for intelligently guessing parameter names from Objective-C method labels.
///
/// Examples:
/// - `initWithTitle` -> `title`
/// - `objectForKey` -> `key`
/// - `valueAtIndex` -> `index`
/// - `setFrame` -> `frame`
/// - `setMaximumNumberOfLines` -> `lines`
/// - `name` -> `name`
private enum NamingIntelligent {
    /// Common prepositions used in Objective-C method names (lowercase).
    /// Ordered by length (longest first) to match longer prepositions before shorter ones.
    private static let prepositions: [String] = [
        "withcontentsof",
        "byappending",
        "byreplacing",
        "fromstring",
        "tostring",
        "containing",
        "including",
        "excluding",
        "replacing",
        "returning",
        "matching",
        "starting",
        "between",
        "through",
        "without",
        "within",
        "during",
        "before",
        "behind",
        "except",
        "under",
        "using",
        "after",
        "about",
        "above",
        "along",
        "among",
        "below",
        "named",
        "called",
        "having",
        "where",
        "until",
        "since",
        "with",
        "from",
        "into",
        "onto",
        "upon",
        "over",
        "like",
        "near",
        "past",
        "for",
        "and",
        "but",
        "nor",
        "yet",
        "via",
        "per",
        "at",
        "by",
        "in",
        "of",
        "on",
        "to",
        "as",
    ]

    /// Prefixes that should be stripped before looking for prepositions.
    private static let prefixes: [String] = [
        "_set",
        "_get",
        "set",
        "get",
    ]

    /// Guesses a parameter name from an Objective-C method label.
    ///
    /// - Parameter label: The method label (e.g., "initWithTitle", "objectForKey")
    /// - Returns: The guessed parameter name (e.g., "title", "key")
    static func parameterName(from label: String) -> String {
        guard !label.isEmpty else { return "arg" }

        var workingLabel = label
        let lowercasedLabel = label.lowercased()

        // First, strip known prefixes like set/get
        for prefix in prefixes {
            if lowercasedLabel.hasPrefix(prefix) && label.count > prefix.count {
                let afterPrefix = label.index(label.startIndex, offsetBy: prefix.count)
                // Make sure the next character is uppercase (word boundary)
                if label[afterPrefix].isUppercase {
                    workingLabel = String(label[afterPrefix...])
                    break
                }
            }
        }

        // Now search for prepositions from the beginning, find the LAST match
        let lowercasedWorking = workingLabel.lowercased()
        var lastMatchEnd: String.Index?

        for preposition in prepositions {
            // Search for all occurrences from the beginning
            var searchStart = lowercasedWorking.startIndex
            while let range = lowercasedWorking.range(of: preposition, range: searchStart ..< lowercasedWorking.endIndex) {
                // Calculate the corresponding range in the working label
                let startDistance = lowercasedWorking.distance(from: lowercasedWorking.startIndex, to: range.lowerBound)
                let endDistance = lowercasedWorking.distance(from: lowercasedWorking.startIndex, to: range.upperBound)
                let originalStart = workingLabel.index(workingLabel.startIndex, offsetBy: startDistance)
                let originalEnd = workingLabel.index(workingLabel.startIndex, offsetBy: endDistance)

                // Check word boundary for camelCase:
                // 1. The preposition must start with uppercase (e.g., "With" in "initWithTitle")
                // 2. After: must be uppercase letter (the next word starts)
                let prepositionStartChar = workingLabel[originalStart]
                let startsWithUppercase = prepositionStartChar.isUppercase

                let hasValidEnd: Bool
                if originalEnd >= workingLabel.endIndex {
                    // Preposition at the end of the label is not valid
                    hasValidEnd = false
                } else {
                    let nextChar = workingLabel[originalEnd]
                    hasValidEnd = nextChar.isUppercase
                }

                if startsWithUppercase && hasValidEnd {
                    // Use the last (rightmost) preposition match
                    if lastMatchEnd == nil || originalEnd > lastMatchEnd! {
                        lastMatchEnd = originalEnd
                    }
                }

                // Move search start forward
                searchStart = range.upperBound
            }
        }

        // Extract the part after the last preposition
        if let end = lastMatchEnd {
            let afterPreposition = String(workingLabel[end...])
            if !afterPreposition.isEmpty {
                return afterPreposition.lowercasedFirst
            }
        }

        // No preposition found, use the working label
        return workingLabel.lowercasedFirst
    }
}
