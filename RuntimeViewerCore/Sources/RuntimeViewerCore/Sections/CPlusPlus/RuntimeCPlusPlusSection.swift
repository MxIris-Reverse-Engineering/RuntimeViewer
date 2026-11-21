import Foundation
import FoundationToolbox
import MachOKit
import MachOKitExtensions
import MachODependencies
import CPlusPlusSymbols
import Semantic

/// An image's C++ classes and namespaces, read through MachOKitExtensions:
/// the scope tree `CPlusPlusSymbolIndexStore` sorts the image's C++ symbols
/// into, and the classes `CPlusPlusClassIndexStore` reads from its run-time
/// type information and vtables, which find a class whose symbols are
/// stripped too.
///
/// The two stores keep each image's index in a cache of their own; this
/// section keeps only the objects made from them and the names it looks
/// classes up by, and asks the stores again for members and vtables when an
/// interface is printed. `RuntimeCPlusPlusSectionFactory.removeAllSections()`
/// drops the stores' indexes of the images it built sections for.
@Loggable(.private)
actor RuntimeCPlusPlusSection<Reading: RuntimeImageReading>: RuntimeCPlusPlusSectioning {
    typealias MachO = Reading.MachO

    enum Error: Swift.Error {
        case invalidRuntimeObject
    }

    nonisolated let imagePath: String

    private let machO: MachO

    /// Where the bases of a standalone file's classes are looked for when a
    /// slot is named through them; `nil` for an image of a process or of a
    /// dyld shared cache, whose other images the stores find themselves.
    private let dependencySearchPaths: [DependencySearchPath]?

    private let objects: [RuntimeObject]

    /// Every object of the tree, nested ones included, by name.
    private let objectsByName: [String: RuntimeObject]

    /// The classes run-time type information shows, by qualified name.
    private let classesByName: [String: CPlusPlusClass]

    /// The mangled type name of every base of the image's classes, by the
    /// base's qualified name.
    private let mangledTypeNamesByBaseName: [String: String]

    /// `imagePath` is the key the factory caches the section under.
    /// `dependencySearchPaths` are the catalog's for the image; they are used
    /// only when `machO` is a standalone file.
    init(imagePath: String, machO: MachO, dependencySearchPaths: [DependencySearchPath], progressContinuation: LoadingEventContinuation? = nil) {
        #log(.info, "Initializing C++ section for image: \(imagePath, privacy: .public)")
        self.imagePath = imagePath
        self.machO = machO
        if let file = machO as? MachOFile, file.cache == nil {
            self.dependencySearchPaths = dependencySearchPaths
        } else {
            self.dependencySearchPaths = nil
        }

        let symbolStore = CPlusPlusSymbolIndexStore.shared
        let classStore = CPlusPlusClassIndexStore.shared
        Self.report(.indexingCPlusPlusSymbols, currentCount: 0, to: progressContinuation)
        symbolStore.prepare(in: machO)
        Self.report(.indexingCPlusPlusSymbols, currentCount: 1, to: progressContinuation)
        Self.report(.indexingCPlusPlusClasses, currentCount: 0, to: progressContinuation)
        let classes = classStore.classes(in: machO)
        Self.report(.indexingCPlusPlusClasses, currentCount: 1, to: progressContinuation)

        var classesByName: [String: CPlusPlusClass] = [:]
        var mangledTypeNamesByBaseName: [String: String] = [:]
        // `classes(in:)` is ascending by name, then typeinfo offset: the
        // first of several hidden classes sharing a name is the one
        // `class(named:in:)` answers with.
        for polymorphicClass in classes where classesByName[polymorphicClass.qualifiedName] == nil {
            classesByName[polymorphicClass.qualifiedName] = polymorphicClass
            for base in polymorphicClass.bases where mangledTypeNamesByBaseName[base.qualifiedName] == nil {
                mangledTypeNamesByBaseName[base.qualifiedName] = base.mangledTypeName
            }
        }
        self.classesByName = classesByName
        self.mangledTypeNamesByBaseName = mangledTypeNamesByBaseName

        let objects = CPlusPlusObjectTreeBuilder(imagePath: imagePath).objects(
            globalScope: Self.treeScope(of: .global, in: machO),
            classPaths: classes.map(\.scopePath)
        )
        self.objects = objects
        var objectsByName: [String: RuntimeObject] = [:]
        func register(_ object: RuntimeObject) {
            objectsByName[object.name] = object
            object.children.forEach(register)
        }
        objects.forEach(register)
        self.objectsByName = objectsByName
        #log(.info, "C++ section for \(imagePath, privacy: .public): \(classes.count, privacy: .public) classes with run-time type information, \(objectsByName.count, privacy: .public) objects")
    }

    private static func report(_ phase: RuntimeObjectsLoadingProgress.Phase, currentCount: Int, to continuation: LoadingEventContinuation?) {
        continuation?.yield(.progress(RuntimeObjectsLoadingProgress(phase: phase, itemDescription: "", currentCount: currentCount, totalCount: 1)))
    }

    /// `scope` and everything below it, as the tree builder takes it.
    private static func treeScope(of scope: CPlusPlusScope, in machO: MachO) -> CPlusPlusObjectTreeBuilder.Scope {
        let store = CPlusPlusSymbolIndexStore.shared
        let kind: CPlusPlusObjectTreeBuilder.Scope.Kind = switch scope.kind {
        case .type: .type
        case .function: .function
        case .namespace: .namespace
        default: .undetermined
        }
        // A function scope is dropped with all of it, so nothing below it is read.
        let children = kind == .function ? [] : store.childScopes(of: scope, in: machO).map { treeScope(of: $0, in: machO) }
        return CPlusPlusObjectTreeBuilder.Scope(
            path: scope.path,
            kind: kind,
            hasMembers: { store.members(of: scope, in: machO).contains(where: isPrinted) },
            children: children
        )
    }

    /// Whether a namespace's interface prints `member`: a function, a
    /// constructor or destructor, or a variable, without a suffix such as
    /// `.cold.1`. A scope holding nothing else — a block's invocation, a
    /// guard variable, a thunk — has nothing to show, and is no object when it
    /// is a namespace.
    static func isPrinted(_ member: CPlusPlusSymbol) -> Bool {
        guard member.name.suffix == nil else { return false }
        switch member.name.kind {
        case .function, .constructor, .destructor, .variable:
            return true
        default:
            return false
        }
    }

    // MARK: - Objects

    func allObjects() -> [RuntimeObject] {
        objects
    }

    func object(named qualifiedName: String) -> RuntimeObject? {
        objectsByName[qualifiedName]
    }

    func mangledTypeName(ofBaseNamed qualifiedName: String) -> String? {
        mangledTypeNamesByBaseName[qualifiedName]
    }

    func primaryBase(ofClassNamed qualifiedName: String) -> RuntimeCPlusPlusBaseReference? {
        guard let polymorphicClass = classesByName[qualifiedName],
              let base = polymorphicClass.bases.first(where: { !$0.isVirtual && $0.offset == 0 }) else { return nil }
        let isInSameImage = if case .sameImage = base.location { true } else { false }
        return RuntimeCPlusPlusBaseReference(qualifiedName: base.qualifiedName, mangledTypeName: base.mangledTypeName, isInSameImage: isInSameImage)
    }

    func derivedClasses(of object: RuntimeObject) -> [RuntimeObject] {
        guard let polymorphicClass = classesByName[object.name] else { return [] }
        return CPlusPlusClassIndexStore.shared.derivedClasses(of: polymorphicClass, in: machO).compactMap { objectsByName[$0.qualifiedName] }
    }

    // MARK: - Interfaces

    func interface(for object: RuntimeObject, options: RuntimeObjectInterface.GenerationOptions) throws -> RuntimeObjectInterface {
        guard let listedObject = objectsByName[object.name] else {
            #log(.default, "No C++ object named \(object.name, privacy: .public) in \(self.imagePath, privacy: .public)")
            throw Error.invalidRuntimeObject
        }
        let printer = CPlusPlusInterfacePrinter(showsAddresses: options.objcHeaderOptions.addMethodIMPAddressComments)
        let interfaceString: SemanticString = switch listedObject.kind {
        case .cPlusPlus(.class):
            printer.interface(of: classDeclaration(of: listedObject))
        default:
            printer.interface(of: namespaceDeclaration(of: listedObject))
        }
        return RuntimeObjectInterface(object: listedObject, interfaceString: interfaceString, interfaceLanguage: .cPlusPlus)
    }

    private var imageName: String {
        imagePath.lastPathComponent.deletingPathExtension
    }

    private func address(forOffset offset: Int) -> String {
        "0x" + machO.addressString(forOffset: offset)
    }

    private func classDeclaration(of object: RuntimeObject) -> CPlusPlusInterfacePrinter.ClassDeclaration {
        var declaration = CPlusPlusInterfacePrinter.ClassDeclaration(qualifiedName: object.name, imageName: imageName)
        var virtualFunctions: Set<CPlusPlusInterfacePrinter.Function> = []
        if let polymorphicClass = classesByName[object.name] {
            let tables = virtualTables(of: polymorphicClass)
            declaration.typeInfoAddress = address(forOffset: polymorphicClass.typeInfoOffset)
            declaration.virtualTableAddress = tables.first(where: \.isPrimary).map { address(forOffset: $0.addressPointOffset) }
            declaration.isRecoveredFromTypeInfoOnly = !polymorphicClass.hasTypeInfoSymbol
            declaration.hasNonUniqueTypeInfo = !polymorphicClass.hasUniqueTypeInfo
            declaration.bases = polymorphicClass.bases.map { .init(qualifiedName: $0.qualifiedName, isVirtual: $0.isVirtual, isPublic: $0.isPublic) }
            declaration.tables = tables.map { table in
                CPlusPlusInterfacePrinter.Table(
                    offsetToTop: table.offsetToTop,
                    subobjectClassName: table.subobjectClassName,
                    slots: table.functions.map(slot)
                )
            }
            for table in tables {
                for function in table.functions {
                    if case .function = function.implementation, let name = function.symbolName {
                        virtualFunctions.insert(Self.function(of: name))
                    }
                }
            }
        }
        if let scope = CPlusPlusSymbolIndexStore.shared.scope(named: object.name, in: machO) {
            var constructorsAndDestructors = MemberCollector()
            var memberFunctions = MemberCollector()
            var variables = MemberCollector()
            for member in CPlusPlusSymbolIndexStore.shared.members(of: scope, in: machO) where member.name.suffix == nil {
                let function = Self.function(of: member.name)
                switch member.name.kind {
                case .constructor, .destructor:
                    guard !virtualFunctions.contains(function) else { continue }
                    constructorsAndDestructors.add(function, address: address(forOffset: member.offset))
                case .function:
                    guard !virtualFunctions.contains(function) else { continue }
                    memberFunctions.add(function, address: address(forOffset: member.offset))
                case .variable:
                    variables.add(Self.variableFunction(of: member.name), address: address(forOffset: member.offset))
                default:
                    continue
                }
            }
            declaration.constructorsAndDestructors = constructorsAndDestructors.members
            declaration.memberFunctions = memberFunctions.members
            declaration.variables = variables.members.map { .init(name: $0.function.name, addresses: $0.addresses) }
        }
        declaration.declaredTypes = object.children.map { .init(qualifiedName: $0.name, isClass: $0.kind == .cPlusPlus(.class)) }
        return declaration
    }

    private func namespaceDeclaration(of object: RuntimeObject) -> CPlusPlusInterfacePrinter.NamespaceDeclaration {
        let isGlobal = object.name == CPlusPlusObjectTreeBuilder.globalNamespaceName
        var declaration = CPlusPlusInterfacePrinter.NamespaceDeclaration(qualifiedName: object.name, imageName: imageName, isGlobal: isGlobal)
        let scope = isGlobal ? CPlusPlusScope.global : CPlusPlusSymbolIndexStore.shared.scope(named: object.name, in: machO)
        if let scope {
            declaration.isUndetermined = scope.kind == .undetermined
            var functions = MemberCollector()
            var variables = MemberCollector()
            for member in CPlusPlusSymbolIndexStore.shared.members(of: scope, in: machO) where member.name.suffix == nil {
                switch member.name.kind {
                case .function, .constructor, .destructor:
                    functions.add(Self.function(of: member.name), address: address(forOffset: member.offset))
                case .variable:
                    variables.add(Self.variableFunction(of: member.name), address: address(forOffset: member.offset))
                default:
                    continue
                }
            }
            declaration.functions = functions.members
            declaration.variables = variables.members.map { .init(name: $0.function.name, addresses: $0.addresses) }
        }
        declaration.declared = object.children.map { .init(qualifiedName: $0.name, isClass: $0.kind == .cPlusPlus(.class)) }
        return declaration
    }

    private func virtualTables(of polymorphicClass: CPlusPlusClass) -> [CPlusPlusVirtualTable] {
        if let dependencySearchPaths, let file = machO as? MachOFile {
            return CPlusPlusClassIndexStore.shared.virtualTables(of: polymorphicClass, in: file, dependencySearchPaths: dependencySearchPaths)
        }
        return CPlusPlusClassIndexStore.shared.virtualTables(of: polymorphicClass, in: machO)
    }

    private func slot(of function: CPlusPlusVirtualFunction) -> CPlusPlusInterfacePrinter.Slot {
        let implementation: CPlusPlusInterfacePrinter.Slot.Implementation = switch function.implementation {
        case .function(let offset): .address(address(forOffset: offset))
        case .imported(_, let installName): .imported(installName: installName)
        case .otherImage(let otherAddress): .otherImage(address: "0x" + String(otherAddress, radix: 16, uppercase: true))
        case .pureVirtual: .pureVirtual
        case .deletedVirtual: .deletedVirtual
        }
        let relation: CPlusPlusInterfacePrinter.Slot.Relation? = function.baseFunction.map { baseFunction in
            baseFunction.isInherited ? .inherited(baseFunction.className) : .overrides(baseFunction.className)
        }
        return CPlusPlusInterfacePrinter.Slot(
            index: function.slotIndex,
            function: function.name.map(Self.function(of:)),
            implementation: implementation,
            relation: relation
        )
    }

    // MARK: - Names

    static func function(of name: CPlusPlusSymbolName) -> CPlusPlusInterfacePrinter.Function {
        var qualifiers: [String] = []
        if name.functionQualifiers.contains(.const) { qualifiers.append("const") }
        if name.functionQualifiers.contains(.volatile) { qualifiers.append("volatile") }
        if name.functionQualifiers.contains(.restrict) { qualifiers.append("restrict") }
        if name.functionQualifiers.contains(.lValueReference) { qualifiers.append("&") }
        if name.functionQualifiers.contains(.rValueReference) { qualifiers.append("&&") }
        return CPlusPlusInterfacePrinter.Function(
            returnType: name.returnType,
            name: name.baseName + (name.templateArguments ?? ""),
            parameters: name.parameters ?? "()",
            qualifiers: qualifiers
        )
    }

    /// A variable's name, carried in a `Function` without parameters so
    /// variables share `MemberCollector` with functions.
    private static func variableFunction(of name: CPlusPlusSymbolName) -> CPlusPlusInterfacePrinter.Function {
        CPlusPlusInterfacePrinter.Function(name: name.baseName + (name.templateArguments ?? ""), parameters: nil)
    }
}

/// The members of a scope by declaration, in the order first met, each with
/// the addresses of every symbol that declares it — the variants of a
/// constructor or a destructor print one declaration.
private struct MemberCollector {
    private(set) var members: [CPlusPlusInterfacePrinter.Member] = []
    private var indicesByFunction: [CPlusPlusInterfacePrinter.Function: Int] = [:]

    mutating func add(_ function: CPlusPlusInterfacePrinter.Function, address: String) {
        if let index = indicesByFunction[function] {
            if !members[index].addresses.contains(address) {
                members[index].addresses.append(address)
            }
        } else {
            indicesByFunction[function] = members.count
            members.append(.init(function: function, addresses: [address]))
        }
    }
}
