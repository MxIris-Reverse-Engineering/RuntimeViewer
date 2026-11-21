import Foundation
import Testing
import MachOKit
import MachOKitExtensions
import CPlusPlusSymbols
@testable import RuntimeViewerCore

/// C++ objects of this process's libc++abi and libc++ (proposal
/// `cplusplus-objects`), listed, printed and followed through an engine that
/// reads the process. libc++abi defines `std::exception`, `std::bad_alloc`,
/// `std::bad_array_new_length` and `std::runtime_error` with exported
/// typeinfo; libc++'s `std::__1::system_error` derives from libc++abi's
/// `std::runtime_error`, which libc++ re-exports.
///
/// Serialized: the two stores MachOKitExtensions keeps C++ indexes in are
/// shared by the whole process, and one test drops what they hold.
@Suite("C++ objects", .serialized)
struct CPlusPlusSectionTests {
    private struct Missing: Error, CustomStringConvertible {
        let description: String
    }

    static let libcxxabiPath = "/usr/lib/libc++abi.dylib"

    static let libcxxPath = "/usr/lib/libc++.1.dylib"

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "CPlusPlusSectionTests.\(label)")
        try await engine.connect()
        return engine
    }

    /// Every object below `objects`, keyed by name.
    static func flattened(_ objects: [RuntimeObject]) -> [String: RuntimeObject] {
        var result: [String: RuntimeObject] = [:]
        func visit(_ object: RuntimeObject) {
            result[object.name] = object
            object.children.forEach(visit)
        }
        objects.forEach(visit)
        return result
    }

    private static func cPlusPlusObject(named name: String, in imagePath: String, on engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: imagePath, includesCPlusPlusObjects: true)
        guard let object = flattened(objects.filter(\.kind.isCPlusPlus))[name] else {
            throw Missing(description: "\(imagePath) lists no C++ object named \(name)")
        }
        return object
    }

    private static func options(showingAddresses: Bool = true) throws -> RuntimeObjectInterface.GenerationOptions {
        var options = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: Data("{}".utf8))
        options.objcHeaderOptions.addMethodIMPAddressComments = showingAddresses
        return options
    }

    // MARK: - Listing

    @Test("libc++abi lists std::bad_array_new_length as a class under the std namespace")
    func libcxxabiListsBadArrayNewLengthUnderStd() async throws {
        let engine = try await Self.makeEngine("listing")
        defer { Task { await engine.stop() } }
        let objects = try await engine.objects(in: Self.libcxxabiPath, includesCPlusPlusObjects: true)
        let standardNamespace = try #require(objects.first { $0.name == "std" })
        #expect(standardNamespace.kind == .cPlusPlus(.namespace))
        let badArrayNewLength = try #require(standardNamespace.children.first { $0.name == "std::bad_array_new_length" })
        #expect(badArrayNewLength.kind == .cPlusPlus(.class))
        #expect(badArrayNewLength.displayName == "bad_array_new_length")
        #expect(badArrayNewLength.imagePath == Self.libcxxabiPath)
        // The Objective-C and Swift objects come first, as before.
        let firstCPlusPlusIndex = try #require(objects.firstIndex { $0.kind.isCPlusPlus })
        let trailingObjects = objects[firstCPlusPlusIndex...]
        #expect(trailingObjects.allSatisfy { $0.kind.isCPlusPlus })
    }

    @Test("every namespace listed has something to show: a symbol it prints or an object inside it")
    func listedNamespacesHaveSomethingToShow() async throws {
        let libobjcPath = "/usr/lib/libobjc.A.dylib"
        let engine = try await Self.makeEngine("namespaces")
        defer { Task { await engine.stop() } }
        let namespaces = Self.flattened(try await engine.objects(in: libobjcPath, includesCPlusPlusObjects: true)).values.filter { $0.kind == .cPlusPlus(.namespace) }
        #expect(!namespaces.isEmpty)
        for namespace in namespaces where namespace.children.isEmpty {
            let text = try #require(try await engine.interface(for: namespace, options: Self.options())).interfaceString.string
            #expect(text.contains("// Functions") || text.contains("// Variables"), "\(namespace.name) prints nothing")
        }
    }

    @Test("without the flag, the objects carry no C++ object")
    func objectsWithoutFlagCarryNoCPlusPlusObjects() async throws {
        let engine = try await Self.makeEngine("without-flag")
        defer { Task { await engine.stop() } }
        let objects = try await engine.objects(in: Self.libcxxabiPath)
        #expect(!objects.contains { $0.kind.isCPlusPlus })
        #expect(await engine.cPlusPlusSectionFactory.existingSection(for: Self.libcxxabiPath) == nil)
    }

    @Test("the C++ progress phases are reported only to a request that asked for C++ objects")
    func progressReportsCPlusPlusPhasesOnlyWhenAsked() async throws {
        func phases(includesCPlusPlusObjects: Bool) async throws -> Set<RuntimeObjectsLoadingProgress.Phase> {
            let engine = try await Self.makeEngine("progress-\(includesCPlusPlusObjects)")
            defer { Task { await engine.stop() } }
            var phases: Set<RuntimeObjectsLoadingProgress.Phase> = []
            for try await event in await engine.objectsWithProgress(in: Self.libcxxPath, includesCPlusPlusObjects: includesCPlusPlusObjects) {
                if case .progress(let progress) = event {
                    phases.insert(progress.phase)
                }
            }
            return phases
        }
        let cPlusPlusPhases: Set<RuntimeObjectsLoadingProgress.Phase> = [.indexingCPlusPlusSymbols, .indexingCPlusPlusClasses]
        #expect(try await phases(includesCPlusPlusObjects: false).isDisjoint(with: cPlusPlusPhases))
        #expect(try await phases(includesCPlusPlusObjects: true).isSuperset(of: cPlusPlusPhases))
    }

    @Test("requests for one image at once build one C++ section")
    func concurrentRequestsBuildOneCPlusPlusSection() async throws {
        let engine = try await Self.makeEngine("concurrent")
        defer { Task { await engine.stop() } }
        async let first = engine.objects(in: Self.libcxxabiPath, includesCPlusPlusObjects: true)
        async let second = engine.objects(in: Self.libcxxabiPath, includesCPlusPlusObjects: true)
        let (firstObjects, secondObjects) = try await (first, second)
        #expect(firstObjects.map(\.name) == secondObjects.map(\.name))
        let section = try #require(await engine.cPlusPlusSectionFactory.existingSection(for: Self.libcxxabiPath))
        let (isExisted, sectionAgain) = try await engine.cPlusPlusSectionFactory.section(for: Self.libcxxabiPath)
        #expect(isExisted)
        #expect(sectionAgain === section)
    }

    @Test("a section reads the same objects from this Mac's dyld shared cache as from the process")
    func sectionReadsTheSameObjectsFromTheCacheFile() async throws {
        let image = try #require(DyldUtilities.machOImage(forPath: Self.libcxxabiPath))
        let hostCache = try #require(FullDyldCache.cachedHost)
        let file = try #require(hostCache.machOFile(by: .path(Self.libcxxabiPath)))
        let fromProcess = RuntimeCPlusPlusSection<RuntimeLoadedImageReading>(imagePath: Self.libcxxabiPath, machO: image, dependencySearchPaths: [])
        let fromFile = RuntimeCPlusPlusSection<RuntimeFileImageReading>(imagePath: Self.libcxxabiPath, machO: file, dependencySearchPaths: [])
        let processObjects = Self.flattened(await fromProcess.allObjects())
        let fileObjects = Self.flattened(await fromFile.allObjects())
        #expect(!processObjects.isEmpty)
        #expect(processObjects.mapValues(\.kind) == fileObjects.mapValues(\.kind))
    }

    // MARK: - Interfaces

    @Test("a class prints its bases and its virtual functions as a pseudo-header")
    func classPrintsBasesAndVirtualFunctions() async throws {
        let engine = try await Self.makeEngine("interface")
        defer { Task { await engine.stop() } }
        let object = try await Self.cPlusPlusObject(named: "std::bad_array_new_length", in: Self.libcxxabiPath, on: engine)
        let interface = try #require(try await engine.interface(for: object, options: Self.options()))
        let text = interface.interfaceString.string
        #expect(interface.interfaceLanguage == .cPlusPlus)
        #expect(text.contains("class std::bad_array_new_length : public std::bad_alloc {"))
        #expect(text.contains("// Virtual functions (primary vtable)"))
        #expect(text.contains("virtual ~bad_array_new_length();"))
        #expect(text.contains("virtual what() const;"))
        #expect(text.contains("typeinfo 0x"))
    }

    @Test("without address comments, the slots still say where they come from")
    func addressCommentsFollowIMPAddressOption() async throws {
        let engine = try await Self.makeEngine("interface-without-addresses")
        defer { Task { await engine.stop() } }
        let object = try await Self.cPlusPlusObject(named: "std::bad_array_new_length", in: Self.libcxxabiPath, on: engine)
        let text = try #require(try await engine.interface(for: object, options: Self.options(showingAddresses: false))).interfaceString.string
        #expect(!text.contains("0x"))
        #expect(text.contains("slot"))
    }

    @Test("a namespace prints the types declared in it, spelled in full")
    func namespacePrintsItsDeclaredTypes() async throws {
        let engine = try await Self.makeEngine("namespace")
        defer { Task { await engine.stop() } }
        let object = try await Self.cPlusPlusObject(named: "std", in: Self.libcxxabiPath, on: engine)
        let text = try #require(try await engine.interface(for: object, options: Self.options())).interfaceString.string
        #expect(text.contains("namespace std {"))
        #expect(text.contains("class std::bad_alloc;"))
    }

    @Test("a base in another image resolves through the image that exports its typeinfo")
    func baseInAnotherImageResolvesThroughExportedTypeInfo() async throws {
        let espressoPath = "/System/Library/PrivateFrameworks/Espresso.framework/Versions/A/Espresso"
        let engine = try await Self.makeEngine("cross-image-espresso")
        defer { Task { await engine.stop() } }
        try await engine.loadImage(at: espressoPath)
        let objects = Self.flattened(try await engine.objects(in: espressoPath, includesCPlusPlusObjects: true))
        let image = try #require(DyldUtilities.machOImage(forPath: espressoPath))
        // A base Espresso lists nothing of and another image exports the typeinfo of.
        let base = try #require(CPlusPlusClassIndexStore.shared.classes(in: image).lazy.flatMap(\.bases).first { base in
            guard case .otherImage = base.location, objects[base.qualifiedName] == nil else { return false }
            return dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZTI" + base.mangledTypeName) != nil
        })
        var information = Dl_info()
        let typeInfo = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_ZTI" + base.mangledTypeName))
        try #require(dladdr(typeInfo, &information) != 0)
        let definingImagePath = String(cString: try #require(information.dli_fname))
        let link = RuntimeObject(name: base.qualifiedName, displayName: base.qualifiedName, kind: .cPlusPlus(.class), imagePath: espressoPath, children: [])
        let interface = try #require(try await engine.interface(for: link, options: Self.options()))
        #expect(interface.object.imagePath == definingImagePath)
        #expect(interface.object.imagePath != espressoPath)
        #expect(interface.interfaceString.string.contains("class \(base.qualifiedName)"))
    }

    @Test("a base its image re-exports symbol by symbol resolves to the image defining it")
    func reExportedBaseStaysInTheReferringImage() async throws {
        let engine = try await Self.makeEngine("cross-image")
        defer { Task { await engine.stop() } }
        // libc++'s `std::__1::bad_function_call` derives from libc++abi's
        // `std::exception`, which libc++ defines nothing of and re-exports
        // symbol by symbol.
        let badFunctionCall = try await Self.cPlusPlusObject(named: "std::__1::bad_function_call", in: Self.libcxxPath, on: engine)
        let text = try #require(try await engine.interface(for: badFunctionCall, options: Self.options())).interfaceString.string
        #expect(text.contains(": public std::exception {"))
        // What the content pane makes of the base's token: its text, in the image it was read in.
        let link = RuntimeObject(name: "std::exception", displayName: "std::exception", kind: .cPlusPlus(.class), imagePath: Self.libcxxPath, children: [])
        let baseInterface = try #require(try await engine.interface(for: link, options: Self.options()))
        #expect(baseInterface.interfaceString.string.contains("class std::exception {"))
        // libc++ re-exports `std::exception`'s destructors and `what()` one by
        // one, as `N_INDR` symbol-table entries. MachOKitExtensions before
        // 3.2.1 indexed them as libc++'s own symbols, so libc++ listed a
        // `std::exception` of its own and the link stayed there.
        #expect(baseInterface.object.imagePath == Self.libcxxabiPath)
        let libcxxObjects = Self.flattened(try await engine.objects(in: Self.libcxxPath, includesCPlusPlusObjects: true))
        #expect(libcxxObjects["std::exception"] == nil)
    }

    @Test("a class the referring image defines symbols of is printed from that image")
    func classWithSymbolsInTheReferringImageIsPrintedThere() async throws {
        let engine = try await Self.makeEngine("referring-image")
        defer { Task { await engine.stop() } }
        _ = try await engine.objects(in: Self.libcxxPath, includesCPlusPlusObjects: true)
        // libc++ defines `std::runtime_error`'s constructors that take a
        // `std::string`; its typeinfo and vtable are libc++abi's.
        let link = RuntimeObject(name: "std::runtime_error", displayName: "std::runtime_error", kind: .cPlusPlus(.class), imagePath: Self.libcxxPath, children: [])
        let interface = try #require(try await engine.interface(for: link, options: Self.options()))
        #expect(interface.object.imagePath == Self.libcxxPath)
        #expect(interface.interfaceString.string.contains("runtime_error(std::__1::basic_string"))
    }

    @Test("a name no image exports the typeinfo of does not resolve")
    func unknownBaseDoesNotResolve() async throws {
        let engine = try await Self.makeEngine("unknown-base")
        defer { Task { await engine.stop() } }
        _ = try await engine.objects(in: Self.libcxxPath, includesCPlusPlusObjects: true)
        let link = RuntimeObject(name: "std::no_such_class", displayName: "std::no_such_class", kind: .cPlusPlus(.class), imagePath: Self.libcxxPath, children: [])
        #expect(try await engine.interface(for: link, options: Self.options()) == nil)
    }

    // MARK: - Hierarchy

    @Test("the hierarchy follows the primary bases")
    func hierarchyFollowsPrimaryBases() async throws {
        let engine = try await Self.makeEngine("hierarchy")
        defer { Task { await engine.stop() } }
        let object = try await Self.cPlusPlusObject(named: "std::bad_array_new_length", in: Self.libcxxabiPath, on: engine)
        #expect(try await engine.hierarchy(for: object) == ["std::bad_array_new_length", "std::bad_alloc", "std::exception"])
    }

    @Test("the superclass chain crosses into the image that defines a base")
    func hierarchyCrossesIntoTheImageDefiningTheBase() async throws {
        let engine = try await Self.makeEngine("superclass-chain")
        defer { Task { await engine.stop() } }
        let systemError = try await Self.cPlusPlusObject(named: "std::__1::system_error", in: Self.libcxxPath, on: engine)
        let chain = try await engine.superclassChain(for: systemError)
        #expect(chain.map(\.name) == ["runtime_error", "exception"])
        #expect(chain.first?.object?.imagePath == Self.libcxxabiPath)
        #expect(chain.allSatisfy { $0.typeKind == .class && $0.isResolved })
    }

    @Test("a namespace has no hierarchy")
    func namespaceHasNoHierarchy() async throws {
        let engine = try await Self.makeEngine("namespace-hierarchy")
        defer { Task { await engine.stop() } }
        let object = try await Self.cPlusPlusObject(named: "std", in: Self.libcxxabiPath, on: engine)
        #expect(try await engine.hierarchy(for: object).isEmpty)
        #expect(try await engine.superclassChain(for: object).isEmpty)
    }

    @Test("the relationships list the classes of the image deriving from a class")
    func relationshipsListDerivedClassesInTheImage() async throws {
        let engine = try await Self.makeEngine("relationships")
        defer { Task { await engine.stop() } }
        let badAlloc = try await Self.cPlusPlusObject(named: "std::bad_alloc", in: Self.libcxxabiPath, on: engine)
        let relationships = try await engine.relationships(for: badAlloc)
        #expect(relationships.subclasses.map(\.name).contains("std::bad_array_new_length"))
        #expect(relationships.conformingTypes.isEmpty)
    }

    // MARK: - Lifetime

    @Test("stopping the engine drops what the stores keep for its images")
    func stoppingEngineRemovesCPlusPlusIndexes() async throws {
        let engine = try await Self.makeEngine("stop")
        _ = try await engine.objects(in: Self.libcxxabiPath, includesCPlusPlusObjects: true)
        let image = try #require(DyldUtilities.machOImage(forPath: Self.libcxxabiPath))
        #expect(CPlusPlusSymbolIndexStore.shared.contains(in: image))
        #expect(CPlusPlusClassIndexStore.shared.contains(in: image))
        await engine.stop()
        let deadline = ContinuousClock.now + .seconds(10)
        while CPlusPlusClassIndexStore.shared.contains(in: image) || CPlusPlusSymbolIndexStore.shared.contains(in: image) {
            guard ContinuousClock.now < deadline else { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!CPlusPlusSymbolIndexStore.shared.contains(in: image))
        #expect(!CPlusPlusClassIndexStore.shared.contains(in: image))
    }
}
