import Foundation
import Testing
@testable import RuntimeViewerCore

@Suite("C++ object tree")
struct CPlusPlusObjectTreeBuilderTests {
    private typealias Scope = CPlusPlusObjectTreeBuilder.Scope

    private static let imagePath = "/usr/lib/libExample.dylib"

    /// A scope whose base name is its last component unless `baseName` says
    /// otherwise, as MachOKitExtensions gives it for a name without template
    /// arguments.
    private static func scope(_ path: [String], _ kind: Scope.Kind, baseName: String? = nil, hasMembers: Bool = false, children: [Scope] = []) -> Scope {
        Scope(path: path, baseName: baseName ?? path.last ?? "", kind: kind, hasMembers: { hasMembers }, children: children)
    }

    /// The objects of a tree whose global scope holds `scopes`. `classPaths`
    /// are classes with run-time type information whose names carry no
    /// template arguments; `classes` any others.
    private static func objects(globalHasMembers: Bool = false, _ scopes: [Scope], classPaths: [[String]] = [], classes: [CPlusPlusObjectTreeBuilder.ClassName] = []) -> [RuntimeObject] {
        CPlusPlusObjectTreeBuilder(imagePath: imagePath).objects(
            globalScope: scope([], .namespace, hasMembers: globalHasMembers, children: scopes),
            classes: classPaths.map { CPlusPlusObjectTreeBuilder.ClassName(path: $0, baseName: $0.last ?? "") } + classes
        )
    }

    /// Every object below `objects`, keyed by name.
    private static func flattened(_ objects: [RuntimeObject]) -> [String: RuntimeObject] {
        var result: [String: RuntimeObject] = [:]
        func visit(_ object: RuntimeObject) {
            result[object.name] = object
            object.children.forEach(visit)
        }
        objects.forEach(visit)
        return result
    }

    @Test("a type scope is a class object, named in full and shown by its last component")
    func typeScopeBecomesClassObject() throws {
        let objects = Self.objects([
            Self.scope(["llvm"], .namespace, children: [
                Self.scope(["llvm", "Value"], .type, hasMembers: true),
            ]),
        ])
        let value = try #require(Self.flattened(objects)["llvm::Value"])
        #expect(value.kind == .cPlusPlus(.class))
        #expect(value.displayName == "Value")
        #expect(value.imagePath == Self.imagePath)
        #expect(objects.map(\.name) == ["llvm"])
        #expect(objects.first?.kind == .cPlusPlus(.namespace))
    }

    @Test("a class only run-time type information shows is placed under its scope path")
    func typeInfoOnlyClassIsPlacedUnderItsScopePath() throws {
        let objects = Self.objects([
            Self.scope(["TST"], .namespace, hasMembers: true),
        ], classPaths: [["TST", "TSTUidOrderNode"]])
        let node = try #require(Self.flattened(objects)["TST::TSTUidOrderNode"])
        #expect(node.kind == .cPlusPlus(.class))
        #expect(objects.first?.children.map(\.name) == ["TST::TSTUidOrderNode"])
    }

    @Test("the missing scopes above such a class are made up, as classes inside a class")
    func missingParentOfTypeInfoOnlyClassBecomesNamespace() throws {
        let objects = Self.objects([], classPaths: [["Outer", "Middle", "Inner"]])
        let byName = Self.flattened(objects)
        #expect(byName["Outer"]?.kind == .cPlusPlus(.namespace))
        #expect(byName["Outer::Middle"]?.kind == .cPlusPlus(.namespace))
        #expect(byName["Outer::Middle::Inner"]?.kind == .cPlusPlus(.class))

        let nested = Self.flattened(Self.objects([], classPaths: [["Owner"], ["Owner", "Middle", "Inner"]]))
        #expect(nested["Owner"]?.kind == .cPlusPlus(.class))
        #expect(nested["Owner::Middle"]?.kind == .cPlusPlus(.class))
    }

    @Test("run-time type information turns an undetermined or namespace scope into a class")
    func typeInfoTurnsUndeterminedScopeIntoClass() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["Undetermined"], .undetermined, hasMembers: true),
            Self.scope(["Namespace"], .namespace, hasMembers: true),
        ], classPaths: [["Undetermined"], ["Namespace"]]))
        #expect(byName["Undetermined"]?.kind == .cPlusPlus(.class))
        #expect(byName["Namespace"]?.kind == .cPlusPlus(.class))
    }

    @Test("an undetermined scope with symbols is a namespace")
    func undeterminedScopeIsNamespace() {
        let byName = Self.flattened(Self.objects([Self.scope(["helpers"], .undetermined, hasMembers: true)]))
        #expect(byName["helpers"]?.kind == .cPlusPlus(.namespace))
    }

    @Test("function scopes are dropped with everything inside them")
    func functionScopesAreDropped() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["app"], .namespace, children: [
                Self.scope(["app", "run()"], .function, hasMembers: true, children: [
                    Self.scope(["app", "run()", "Local"], .type, hasMembers: true),
                ]),
                Self.scope(["app", "Kept"], .type),
            ]),
        ], classPaths: [["app", "run()", "Local"], ["main()", "Lambda"]]))
        #expect(byName.keys.sorted() == ["app", "app::Kept"])
    }

    @Test("a namespace with no symbol and nothing below it is left out; an empty type is kept")
    func emptyNamespacesAreDropped() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["empty"], .namespace, children: [
                Self.scope(["empty", "alsoEmpty"], .namespace),
            ]),
            Self.scope(["holder"], .namespace, children: [
                Self.scope(["holder", "Marker"], .type),
            ]),
        ]))
        #expect(byName.keys.sorted() == ["holder", "holder::Marker"])
    }

    @Test("a namespace that keeps something below it is not asked for its members")
    func namespaceWithChildrenIsNotAskedForMembers() {
        let asked = AskedFlag()
        let objects = CPlusPlusObjectTreeBuilder(imagePath: Self.imagePath).objects(
            globalScope: Self.scope([], .namespace, children: [
                Scope(path: ["std"], baseName: "std", kind: .namespace, hasMembers: { asked.set(); return false }, children: [
                    Self.scope(["std", "exception"], .type),
                ]),
            ]),
            classes: []
        )
        #expect(objects.map(\.name) == ["std"])
        #expect(!asked.value)
    }

    @Test("symbols at global scope get the Global Namespace object")
    func globalMembersGetGlobalNamespaceObject() throws {
        let objects = Self.objects(globalHasMembers: true, [Self.scope(["Widget"], .type)])
        let global = try #require(objects.first { $0.name == CPlusPlusObjectTreeBuilder.globalNamespaceName })
        #expect(global.displayName == "Global Namespace")
        #expect(global.kind == .cPlusPlus(.namespace))
        #expect(Self.objects([Self.scope(["Widget"], .type)]).allSatisfy { $0.name != "::" })
    }

    @Test("a component is a function when a parenthesis stands outside its template arguments")
    func functionComponentsAreRecognized() {
        #expect(CPlusPlusObjectTreeBuilder.isFunctionComponent("run()"))
        #expect(CPlusPlusObjectTreeBuilder.isFunctionComponent("compare(int, int) const"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("(anonymous namespace)"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("function<void (int)>"))
        #expect(!CPlusPlusObjectTreeBuilder.isFunctionComponent("vector<int, std::__1::allocator<int>>"))
    }

    @Test("children are sorted, classes before namespaces")
    func childrenAreSorted() {
        let objects = Self.objects([
            Self.scope(["ns"], .namespace, children: [
                Self.scope(["ns", "zeta"], .namespace, hasMembers: true),
                Self.scope(["ns", "Beta"], .type),
                Self.scope(["ns", "Alpha"], .type),
            ]),
        ])
        #expect(objects.first?.children.map(\.displayName) == ["Alpha", "Beta", "zeta"])
    }

    // MARK: - Class templates

    private static let vectorOfInt = "vector<int, std::__1::allocator<int>>"

    private static let vectorOfCharacter = "vector<char, std::__1::allocator<char>>"

    private static func standardLibrary(_ scopes: [Scope]) -> [Scope] {
        [Self.scope(["std"], .namespace, children: [Self.scope(["std", "__1"], .namespace, children: scopes)])]
    }

    @Test("the specializations of one class template sit under one node named after the template")
    func specializationsOfOneTemplateSitUnderOneNodeNamedAfterIt() throws {
        let byName = Self.flattened(Self.objects(Self.standardLibrary([
            Self.scope(["std", "__1", Self.vectorOfInt], .type, baseName: "vector", hasMembers: true),
            Self.scope(["std", "__1", Self.vectorOfCharacter], .type, baseName: "vector", hasMembers: true),
        ])))
        let template = try #require(byName["std::__1::vector"])
        #expect(template.kind == .cPlusPlus(.classTemplate))
        #expect(template.children.map(\.name) == ["std::__1::\(Self.vectorOfCharacter)", "std::__1::\(Self.vectorOfInt)"])
        #expect(byName["std::__1"]?.children.map(\.name) == ["std::__1::vector"])
    }

    @Test("a template with a single specialization gets a node too")
    func aSingleSpecializationIsGroupedToo() throws {
        let byName = Self.flattened(Self.objects(Self.standardLibrary([
            Self.scope(["std", "__1", Self.vectorOfInt], .type, baseName: "vector", hasMembers: true),
        ])))
        let template = try #require(byName["std::__1::vector"])
        #expect(template.kind == .cPlusPlus(.classTemplate))
        #expect(template.children.map(\.name) == ["std::__1::\(Self.vectorOfInt)"])
    }

    @Test("the template node is named by its scope and the template, and shows the template's name")
    func templateNodeIsNamedByItsScopeAndShowsTheTemplateName() throws {
        let objects = Self.objects(Self.standardLibrary([
            Self.scope(["std", "__1", Self.vectorOfInt], .type, baseName: "vector", hasMembers: true),
        ]))
        let template = try #require(Self.flattened(objects)["std::__1::vector"])
        #expect(template.displayName == "vector")
        #expect(template.imagePath == Self.imagePath)
    }

    @Test("specializations keep their full names and what is below them")
    func specializationsKeepTheirFullNamesAndTheirSubtrees() throws {
        let byName = Self.flattened(Self.objects(Self.standardLibrary([
            Self.scope(["std", "__1", Self.vectorOfInt], .type, baseName: "vector", children: [
                Self.scope(["std", "__1", Self.vectorOfInt, "iterator"], .type, hasMembers: true),
            ]),
        ])))
        let specialization = try #require(byName["std::__1::\(Self.vectorOfInt)"])
        #expect(specialization.displayName == Self.vectorOfInt)
        #expect(specialization.kind == .cPlusPlus(.class))
        #expect(specialization.children.map(\.name) == ["std::__1::\(Self.vectorOfInt)::iterator"])
    }

    @Test("one template name in two scopes makes two nodes")
    func sameTemplateNameInTwoScopesMakesTwoNodes() {
        let byName = Self.flattened(Self.objects([
            Self.scope(["first"], .namespace, children: [Self.scope(["first", "Box<int>"], .type, baseName: "Box", hasMembers: true)]),
            Self.scope(["second"], .namespace, children: [Self.scope(["second", "Box<int>"], .type, baseName: "Box", hasMembers: true)]),
        ]))
        #expect(byName["first::Box"]?.children.map(\.name) == ["first::Box<int>"])
        #expect(byName["second::Box"]?.children.map(\.name) == ["second::Box<int>"])
    }

    @Test("a specialization the symbols leave undetermined is gathered all the same")
    func undeterminedTemplatedScopeIsGroupedLikeAClass() throws {
        let byName = Self.flattened(Self.objects([
            Self.scope(["Box<int>"], .undetermined, baseName: "Box", hasMembers: true),
            Self.scope(["Box<char>"], .type, baseName: "Box", hasMembers: true),
        ]))
        let template = try #require(byName["Box"])
        #expect(template.kind == .cPlusPlus(.classTemplate))
        #expect(template.children.map(\.name) == ["Box<char>", "Box<int>"])
        // Its kind stays what the symbols show.
        #expect(byName["Box<int>"]?.kind == .cPlusPlus(.namespace))
    }

    @Test("a class only run-time type information shows is gathered by its base name")
    func classOnlyTypeInformationShowsIsGroupedByItsBaseName() throws {
        let byName = Self.flattened(Self.objects(
            [Self.scope(["app"], .namespace, hasMembers: true)],
            classes: [CPlusPlusObjectTreeBuilder.ClassName(path: ["app", "Handler<Event>"], baseName: "Handler")]
        ))
        let template = try #require(byName["app::Handler"])
        #expect(template.kind == .cPlusPlus(.classTemplate))
        #expect(template.children.map(\.name) == ["app::Handler<Event>"])
    }

    @Test("a scope made up on the way to a class has no base name and stays where it is")
    func madeUpScopeWithoutBaseNameStaysWhereItIs() {
        let byName = Self.flattened(Self.objects([], classes: [
            CPlusPlusObjectTreeBuilder.ClassName(path: ["Outer<int>", "Inner"], baseName: "Inner"),
        ]))
        #expect(byName["Outer"] == nil)
        #expect(byName["Outer<int>"]?.kind == .cPlusPlus(.namespace))
        #expect(byName["Outer<int>::Inner"]?.kind == .cPlusPlus(.class))
    }

    @Test("no node is made for a template whose name a sibling already has")
    func noTemplateNodeWhenASiblingAlreadyHasItsName() {
        let objects = Self.objects([
            Self.scope(["Box"], .type, hasMembers: true),
            Self.scope(["Box<int>"], .type, baseName: "Box", hasMembers: true),
        ])
        #expect(objects.map(\.name) == ["Box", "Box<int>"])
        #expect(objects.allSatisfy { $0.kind == .cPlusPlus(.class) })
    }

    @Test("specializations at global scope are gathered at the top level")
    func globalScopeSpecializationsAreGroupedAtTheTopLevel() throws {
        let objects = Self.objects(globalHasMembers: true, [
            Self.scope(["Box<int>"], .type, baseName: "Box", hasMembers: true),
            Self.scope(["Widget"], .type),
        ])
        #expect(objects.map(\.name) == ["Widget", "Box", CPlusPlusObjectTreeBuilder.globalNamespaceName])
        #expect(objects.first { $0.name == "Box" }?.kind == .cPlusPlus(.classTemplate))
    }

    @Test("template nodes sort after the classes and before the namespaces")
    func templateNodesSortAfterClassesAndBeforeNamespaces() {
        let objects = Self.objects([
            Self.scope(["ns"], .namespace, children: [
                Self.scope(["ns", "alpha"], .namespace, hasMembers: true),
                Self.scope(["ns", "Array<int>"], .type, baseName: "Array", hasMembers: true),
                Self.scope(["ns", "Zeta"], .type),
            ]),
        ])
        #expect(objects.first?.children.map(\.displayName) == ["Zeta", "Array", "alpha"])
    }

    @Test("replacing template nodes gives back the tree without them")
    func replacingTemplateNodesGivesTheFlatTree() {
        let objects = Self.objects(globalHasMembers: true, [
            Self.scope(["Box<int>"], .type, baseName: "Box", hasMembers: true),
            Self.scope(["ns"], .namespace, children: [
                Self.scope(["ns", "alpha"], .namespace, hasMembers: true),
                Self.scope(["ns", "Array<int>"], .type, baseName: "Array", hasMembers: true),
                Self.scope(["ns", "Zeta"], .type),
            ]),
        ])
        let replaced = objects.flatMap(\.replacingCPlusPlusClassTemplatesWithSpecializations).sorted()
        // The namespaces by what they show: "Global Namespace" before "ns".
        #expect(replaced.map(\.name) == ["Box<int>", CPlusPlusObjectTreeBuilder.globalNamespaceName, "ns"])
        #expect(replaced.first { $0.name == "ns" }?.children.map(\.displayName) == ["Array<int>", "Zeta", "alpha"])
        #expect(!Self.flattened(replaced).values.contains { $0.kind == .cPlusPlus(.classTemplate) })
    }
}

/// Whether a closure was called, readable after the call.
private final class AskedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var isSet = false

    var value: Bool { lock.withLock { isSet } }

    func set() { lock.withLock { isSet = true } }
}
