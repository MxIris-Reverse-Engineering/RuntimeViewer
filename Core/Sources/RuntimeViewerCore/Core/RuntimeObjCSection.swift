import Foundation
import MachOObjCSection
import ObjCDump
import Semantic
import Utilities
import ObjCTypeDecodeKit
import ClassDumpRuntimeSwift

actor RuntimeObjCSection {
    enum Error: Swift.Error {
        case invalidMachOImage
        case invalidRuntimeObjectName
    }

    let imagePath: String

    private let machO: MachOImage

    private var classes: [String: [ObjCClassInfo]] = [:]

    private var protocols: [String: ObjCProtocolInfo] = [:]

    private var categories: [String: ObjCCategoryInfo] = [:]

    private var classInfoCache: [String: ObjCClassInfo] = [:]
    
    init(imagePath: String) async throws {
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else { throw Error.invalidMachOImage }
        self.imagePath = imagePath
        self.machO = machO
        try await prepare()
    }

    private func prepare() async throws {
        var classByName: [String: [ObjCClassInfo]] = [:]
        var protocolByName: [String: ObjCProtocolInfo] = [:]
        var categoryByName: [String: ObjCCategoryInfo] = [:]
        let classes = machO.objc.classes64.orEmpty.compactMap { infoWithSuperclasses(class: $0, in: machO) } + machO.objc.classes32.orEmpty.compactMap { infoWithSuperclasses(class: $0, in: machO) } + machO.objc.nonLazyClasses64.orEmpty.compactMap { infoWithSuperclasses(class: $0, in: machO) } + machO.objc.nonLazyClasses32.orEmpty.compactMap { infoWithSuperclasses(class: $0, in: machO) }
        for cls in classes {
            if let currentClass = cls.first {
                classByName[currentClass.name] = cls
            }
        }
        let protocols = machO.objc.protocols64.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.protocols32.orEmpty.compactMap { $0.info(in: machO) }

        for proto in protocols {
            protocolByName[proto.name] = proto
        }

        let categories = machO.objc.categories64.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.categories2_64.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.categories32.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.categories2_32.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.nonLazyCategories64.orEmpty.compactMap { $0.info(in: machO) } + machO.objc.nonLazyCategories32.orEmpty.compactMap { $0.info(in: machO) }

        for category in categories {
            categoryByName[category.uniqueName] = category
        }

        self.classes = classByName
        self.protocols = protocolByName
        self.categories = categoryByName
    }


    private func infoWithSuperclasses<Class: ObjCClassProtocol>(class cls: Class, in machO: MachOImage) -> [ObjCClassInfo] {
        guard let className = cls.name(in: machO) else { return [] }

        var currentInfo: ObjCClassInfo?

        if let cacheInfo = classInfoCache[className] {
            currentInfo = cacheInfo
        } else {
            let info = cls.info(in: machO)
            currentInfo = info
            classInfoCache[className] = info
        }

        guard let currentInfo else { return [] }

        var superclass = cls.superClass(in: machO)?.1

        var resultInfos: [ObjCClassInfo] = [currentInfo]

        while let currentSuperclass = superclass {
            defer {
                superclass = currentSuperclass.superClass(in: machO)?.1
            }
            guard let superClassName = currentSuperclass.name(in: machO) else { continue }
            var superclassInfo: ObjCClassInfo?
            if let cacheInfo = classInfoCache[superClassName] {
                superclassInfo = cacheInfo
            } else {
                let info = currentSuperclass.info(in: machO)
                superclassInfo = info
                classInfoCache[superClassName] = info
            }
            if let superclassInfo {
                resultInfos.append(superclassInfo)
            }
        }

        return resultInfos
    }

    func allNames() async throws -> [RuntimeObjectName] {
        var results: [RuntimeObjectName] = []
        for cls in classes.keys {
            results.append(.init(name: cls, displayName: cls, kind: .objc(.type(.class)), imagePath: imagePath, children: []))
        }

        for proto in protocols.keys {
            results.append(.init(name: proto, displayName: proto, kind: .objc(.type(.protocol)), imagePath: imagePath, children: []))
        }

        for category in categories.keys {
            results.append(.init(name: category, displayName: category, kind: .objc(.category(.class)), imagePath: imagePath, children: []))
        }

        return results
    }

    func interface(for name: RuntimeObjectName, using options: CDGenerationOptions) async throws -> RuntimeObjectInterface {
        switch name.kind {
        case .objc(.type(.class)):
            if let classInfos = classes[name.name], let currentClassInfo = classInfos.first {
                let superclassInfos = classInfos.dropFirst()
                var finalClassInfo = classInfos.first
                var needsStripClassProperties: [ObjCPropertyInfo] = []
                var needsStripProperties: [ObjCPropertyInfo] = []
                var needsStripClassMethods: [ObjCMethodInfo] = []
                var needsStripMethods: [ObjCMethodInfo] = []
                var needsStripIvars: [ObjCIvarInfo] = []
                if options.stripOverrides {
                    for superclassInfo in superclassInfos {
                        needsStripClassProperties.append(contentsOf: superclassInfo.classProperties)
                        needsStripProperties.append(contentsOf: superclassInfo.properties)
                        needsStripClassMethods.append(contentsOf: superclassInfo.classMethods)
                        needsStripMethods.append(contentsOf: superclassInfo.methods)
                    }
                }
                if options.stripProtocolConformance {
                    for protocolInfo in currentClassInfo.protocols {
                        needsStripClassProperties.append(contentsOf: protocolInfo.classProperties)
                        needsStripProperties.append(contentsOf: protocolInfo.properties)
                        needsStripClassMethods.append(contentsOf: protocolInfo.classMethods)
                        needsStripMethods.append(contentsOf: protocolInfo.methods)
                    }
                }
                if options.stripSynthesized {
                    var needsStripIvarNames: Set<String> = []

                    for property in currentClassInfo.properties {
                        if let ivar = property.ivar {
                            needsStripIvarNames.insert(ivar)
                        }
                    }

                    for ivar in currentClassInfo.ivars {
                        if needsStripIvarNames.contains(ivar.name) {
                            needsStripIvars.append(ivar)
                        }
                    }
                }

                finalClassInfo = ObjCClassInfo(
                    name: currentClassInfo.name,
                    version: currentClassInfo.version,
                    imageName: currentClassInfo.imageName,
                    instanceSize: currentClassInfo.instanceSize,
                    superClassName: currentClassInfo.superClassName,
                    protocols: currentClassInfo.protocols,
                    ivars: currentClassInfo.ivars.removing(contentsOf: needsStripIvars),
                    classProperties: currentClassInfo.classProperties.removing(contentsOf: needsStripClassProperties),
                    properties: currentClassInfo.properties.removing(contentsOf: needsStripProperties),
                    classMethods: currentClassInfo.classMethods.removing(contentsOf: needsStripClassMethods),
                    methods: currentClassInfo.methods.removing(contentsOf: needsStripMethods)
                )

                if let finalClassInfo {
                    return .init(name: name, interfaceString: finalClassInfo.semanticString(using: options))
                }
            }
        case .objc(.type(.protocol)):
            if let interfaceString = protocols[name.name]?.semanticString(using: options) {
                return .init(name: name, interfaceString: interfaceString)
            }
        case .objc(.category(.class)):
            if let interfaceString = categories[name.name]?.semanticString(using: options) {
                return .init(name: name, interfaceString: interfaceString)
            }
        default:
            break
        }
        throw Error.invalidRuntimeObjectName
    }

    func classHierarchy(for name: RuntimeObjectName) async throws -> [String] {
        guard case .objc(.type(.class)) = name.kind,
              let classInfos = classes[name.name]
        else { return [] }
        return classInfos.map(\.name)
    }
}

extension ObjCClassInfo {}

extension ObjCCategoryInfo {
    var uniqueName: String {
        "\(className)(\(name))"
    }
}

extension ObjCClassInfo {
    @SemanticStringBuilder
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
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
                    ivar.semanticString(using: options)
                }
            }
        } prefix: {
            " {"
        } suffix: {
            "}"
        }

        Joined(prefix: BreakLine(), suffix: BreakLine()) {
            BlockList {
                for property in classProperties {
                    property.semanticString(using: options)
                }
            }
            BlockList {
                for property in properties {
                    property.semanticString(using: options)
                }
            }
            BlockList {
                for method in classMethods {
                    method.semanticString(using: options)
                }
            }
            BlockList {
                for method in methods {
                    method.semanticString(using: options)
                }
            }
        }

        Keyword("@end")
    }
}

extension ObjCProtocolInfo {
    @SemanticStringBuilder
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
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
                        property.semanticString(using: options)
                    }
                }
                BlockList {
                    for property in properties {
                        property.semanticString(using: options)
                    }
                }
                BlockList {
                    for method in classMethods {
                        method.semanticString(using: options)
                    }
                }
                BlockList {
                    for method in methods {
                        method.semanticString(using: options)
                    }
                }
            } prefix: {
                Keyword("@required")
                BreakLine()
            }

            Joined {
                BlockList {
                    for property in optionalClassProperties {
                        property.semanticString(using: options)
                    }
                }
                BlockList {
                    for property in optionalProperties {
                        property.semanticString(using: options)
                    }
                }
                BlockList {
                    for method in optionalClassMethods {
                        method.semanticString(using: options)
                    }
                }
                BlockList {
                    for method in optionalMethods {
                        method.semanticString(using: options)
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
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
        Keyword("@interface")
        Space()
        TypeName(kind: .class, className)
        " (\(name))"

        Joined(separator: ", ", prefix: " <", suffix: ">") {
            for `protocol` in protocols {
                TypeName(kind: .protocol, `protocol`.name)
            }
        }

        Joined(prefix: BreakLine(), suffix: BreakLine()) {
            BlockList {
                for property in classProperties {
                    property.semanticString(using: options)
                }
            }

            BlockList {
                for property in properties {
                    property.semanticString(using: options)
                }
            }

            BlockList {
                for method in classMethods {
                    method.semanticString(using: options)
                }
            }

            BlockList {
                for method in methods {
                    method.semanticString(using: options)
                }
            }
        }

        Keyword("@end")
    }
}

extension ObjCIvarInfo {
    @SemanticStringBuilder
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
        if let type, case .bitField(let width) = type {
            let field = ObjCField(
                type: .int,
                name: name,
                bitWidth: width
            )
            field.semanticString(fallbackName: name)
        } else {
            if [.char, .uchar].contains(type) {
                Keyword("BOOL")
                Space()
                Variable(name)
                ";"
            } else {
                let type = type?.semanticDecoded()
                if let type {
                    type
                    Variable(name)
                    ";"
                } else {
                    TypeName(kind: .other, "unknown")
                    Space()
                    Variable(name)
                    ";"
                }
            }
        }

        if options.addIvarOffsetComments {
            Space()
            Comment("offset: \(String(offset, radix: 16, uppercase: true))")
        }
    }
}

extension ObjCPropertyInfo {
    @SemanticStringBuilder
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
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

            if let getter = attributes.compactMap({
                if case .getter(let name) = $0 { return name }
                return nil
            }).first {
                Group {
                    Keyword("getter")
                    "="
                    getter
                }
            }

            if let setter = attributes.compactMap({
                if case .setter(let name) = $0 { return name }
                return nil
            }).first {
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

        let type: ObjCType? = attributes.compactMap {
            if case .type(let type) = $0, let type { return type }
            return nil
        }.first

        let typeString = type?.semanticDecodedForArgument()

        if let typeString {
            typeString
        } else {
            Error("unknown")
        }

        if !(typeString?.string.last == "*" || typeString == nil) {
            Space()
        }

        MemberDeclaration(name)

        ";"
    }
}

extension ObjCMethodInfo {
    @SemanticStringBuilder
    func semanticString(using options: CDGenerationOptions) -> SemanticString {
        if isClassMethod {
            "+"
        } else {
            "-"
        }

        Space()

        "("
        if let returnType = type?.returnType {
            returnType.semanticDecodedForArgument()
        } else {
            Error("unknown")
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
                    argumentInfos[index].type.semanticDecodedForArgument()
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
    func semanticString(fallbackName: String, level: Int = 1) -> SemanticString {
        type.semanticDecoded(level: level)
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
    func semanticDecodedForArgument() -> SemanticString {
        switch self {
        case .struct(let name, let fields):
            if let name {
                TypeName(kind: .struct, name)
            } else {
                Keyword("struct")
                Joined {
                    if let fields {
                        for (index, field) in fields.enumerated() {
                            field.type.semanticDecodedForArgument()
                            Space()
                            Variable(field.name ?? "x\(index)")
                            if let bitWidth = field.bitWidth {
                                " : "
                                Numeric(bitWidth)
                            }
                            ";"
                        }
                    }
                } prefix: {
                    " { "
                } suffix: {
                    " }"
                }
            }
        case .union(let name, let fields):
            if let name {
                TypeName(kind: .other, name)
            } else {
                Keyword("union")
                Joined {
                    if let fields {
                        for (index, field) in fields.enumerated() {
                            field.type.semanticDecodedForArgument()
                            Space()
                            Variable(field.name ?? "x\(index)")
                            if let bitWidth = field.bitWidth {
                                " : "
                                Numeric(bitWidth)
                            }
                            ";"
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
            type.semanticDecodedForArgument()
            Space()
            "*"
        case .modified(let modifier, let type):
            modifier.semanticDecoded(level: 0)
            Space()
            type.semanticDecodedForArgument()
        default:
            semanticDecoded(level: 0)
        }
    }

    @SemanticStringBuilder
    func semanticDecoded(level: Int = 1) -> SemanticString {
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
            Error("unknown")
        case .charPtr:
            Keyword("char")
            Space()
            "*"
        case .atom:
            Keyword("atom")
        case .object(let name):
            if let name {
                if name.first == "<" && name.last == ">" {
                    Keyword("id")
                    Space()
                    "<"
                    TypeName(kind: .protocol, String(name.dropFirst(1).dropLast(1)))
                    ">"
                } else {
                    TypeName(kind: .class, name)
                    Space()
                    "*"
                }
            } else {
                Keyword("id")
            }
        case .block(let ret, let args):
            if let ret, let args {
                ret.semanticDecoded(level: level)
                " (^)("
                Joined(separator: ", ") {
                    for arg in args {
                        arg.semanticDecoded(level: level)
                    }
                }
                ")"
            } else {
                Keyword("id")
                Space()
                InlineComment(" block ")
            }
        case .functionPointer:
            Keyword("void")
            Space()
            "*"
            InlineComment(" function pointer ")
        case .array(let type, let size):
            type.semanticDecoded(level: level)
            "["
            if let size {
                Numeric(size)
            }
            "]"
        case .pointer(let type):
            type.semanticDecoded(level: level)
            Space()
            "*"
        case .bitField(let width):
            Keyword("int")
            Space()
            Variable("x")
            " : "
            Numeric(width)
        case .union(let name, let fields):
            Keyword("union")
            if let name {
                Space()
                TypeName(kind: .other, name)
            }
            Joined {
                if let fields {
                    MemberList(level: level + 1) {
                        for (index, field) in fields.enumerated() {
                            field.semanticString(fallbackName: "x\(index)", level: level + 1)
                        }
                    }
                }
            } prefix: {
                " {"
            } suffix: {
                Indent(level: level)
                "}"
            }.if(fields != nil || name == nil)
        case .struct(let name, let fields):
            Keyword("struct")
            if let name {
                Space()
                TypeName(kind: .struct, name)
            }
            Joined {
                if let fields {
                    MemberList(level: level + 1) {
                        for (index, field) in fields.enumerated() {
                            field.semanticString(fallbackName: "x\(index)", level: level + 1)
                        }
                    }
                }
            } prefix: {
                " {"
            } suffix: {
                Indent(level: level)
                "}"
            }.if(fields != nil || name == nil)
        case .modified(let modifier, let type):
            modifier.semanticDecoded(level: level)
            Space()
            type.semanticDecoded(level: level)
        case .other(let string):
            string
        }
    }
}

extension Optional where Wrapped: Collection {
    var orEmpty: [Wrapped.Element] {
        switch self {
        case .none:
            return []
        case .some(let wrapped):
            return .init(wrapped)
        }
    }
}

extension Array where Element: Equatable {
    @discardableResult
    mutating func removeFirst(_ element: Element) -> Element? {
        if let index = firstIndex(of: element) {
            return remove(at: index)
        }
        return nil
    }

    mutating func removeAll(_ element: Element) {
        removeAll(where: { $0 == element })
    }

    func removingFirst(_ element: Element) -> [Element] {
        var newArray = self
        newArray.removeFirst(element)
        return newArray
    }

    func removingAll(_ element: Element) -> [Element] {
        return filter { $0 != element }
    }

    mutating func remove(contentsOf elements: [Element]) {
        removeAll { elements.contains($0) }
    }

    func removing(contentsOf elements: [Element]) -> [Element] {
        return filter { !elements.contains($0) }
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
enum NamingIntelligent {
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

extension String {
    /// Returns the string with its first character lowercased.
    fileprivate var lowercasedFirst: String {
        guard let first = first else { return self }
        return first.lowercased() + dropFirst()
    }
}

extension ObjCPropertyInfo {
    var ivar: String? {
        attributes.compactMap({
            if case let .ivar(name) = $0 { return name }
            return nil
        }).first
    }
}
