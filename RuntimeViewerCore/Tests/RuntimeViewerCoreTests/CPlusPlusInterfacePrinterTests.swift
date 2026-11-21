import Foundation
import Testing
import Semantic
@testable import RuntimeViewerCore

@Suite("C++ interface printer")
struct CPlusPlusInterfacePrinterTests {
    private typealias Printer = CPlusPlusInterfacePrinter

    private static let destructor = Printer.Function(name: "~Widget")
    private static let draw = Printer.Function(name: "draw", parameters: "(int)", qualifiers: ["const"])

    private static func widget(
        bases: [Printer.Base] = [.init(qualifiedName: "ui::View", isVirtual: false, isPublic: true)],
        tables: [Printer.Table] = [],
        constructors: [Printer.Member] = [],
        functions: [Printer.Member] = [],
        variables: [Printer.Variable] = [],
        declared: [Printer.Declared] = []
    ) -> Printer.ClassDeclaration {
        var declaration = Printer.ClassDeclaration(qualifiedName: "ui::Widget", imageName: "UIKitCore", typeInfoAddress: "0x100", virtualTableAddress: "0x200")
        declaration.bases = bases
        declaration.tables = tables
        declaration.constructorsAndDestructors = constructors
        declaration.memberFunctions = functions
        declaration.variables = variables
        declaration.declaredTypes = declared
        return declaration
    }

    private static func text(_ declaration: Printer.ClassDeclaration, showsAddresses: Bool = true) -> String {
        Printer(showsAddresses: showsAddresses).interface(of: declaration).string
    }

    /// The text of every span of `type`.
    private static func spans(of type: SemanticType, in string: SemanticString) -> [String] {
        var spans: [String] = []
        string.enumerate { text, spanType in
            if spanType == type { spans.append(text) }
        }
        return spans
    }

    @Test("a class prints its bases with virtual and their access")
    func classPrintsBasesWithVirtualAndAccess() {
        let text = Self.text(Self.widget(bases: [
            .init(qualifiedName: "ui::View", isVirtual: false, isPublic: true),
            .init(qualifiedName: "ui::Responder", isVirtual: true, isPublic: true),
            .init(qualifiedName: "detail::Mixin", isVirtual: false, isPublic: false),
        ]))
        #expect(text.contains("// UIKitCore · typeinfo 0x100 · vtable 0x200\n"))
        #expect(text.contains("class ui::Widget : public ui::View, virtual public ui::Responder, /* not public */ detail::Mixin {\n"))
        #expect(text.hasSuffix("};"))
    }

    @Test("a virtual destructor's two slots print as one line")
    func virtualDestructorSlotsCollapseIntoOneLine() {
        let text = Self.text(Self.widget(tables: [.init(offsetToTop: 0, slots: [
            .init(index: 0, function: Self.destructor, implementation: .address("0x10"), relation: .overrides("ui::View")),
            .init(index: 1, function: Self.destructor, implementation: .address("0x20"), relation: .overrides("ui::View")),
        ])]))
        #expect(text.contains("    virtual ~Widget();  // slots 0–1  0x10, 0x20  overrides ui::View\n"))
    }

    @Test("constructor variants print as one declaration with every address")
    func constructorVariantsCollapseIntoOneLine() {
        let text = Self.text(Self.widget(constructors: [.init(function: .init(name: "Widget"), addresses: ["0x30", "0x40"])]))
        #expect(text.contains("    // Constructors and destructors\n    Widget();  // 0x30, 0x40\n"))
    }

    @Test("a slot named through its base says whether it is inherited or overridden")
    func slotNamedThroughBaseSaysInheritedOrOverrides() {
        let text = Self.text(Self.widget(tables: [.init(offsetToTop: 0, slots: [
            .init(index: 2, function: Self.draw, implementation: .address("0x50"), relation: .overrides("ui::View")),
            .init(index: 3, function: .init(name: "layout"), implementation: .address("0x60"), relation: .inherited("ui::View")),
            .init(index: 4, function: .init(name: "update"), implementation: .address("0x70"), relation: nil),
        ])]))
        #expect(text.contains("virtual draw(int) const;  // slot 2  0x50  overrides ui::View\n"))
        #expect(text.contains("virtual layout();  // slot 3  0x60  inherited from ui::View\n"))
        #expect(text.contains("virtual update();  // slot 4  0x70\n"))
    }

    @Test("a slot nothing names prints its slot number")
    func unnamedSlotPrintsSlotNumberOnly() {
        let text = Self.text(Self.widget(tables: [.init(offsetToTop: 0, slots: [
            .init(index: 21, function: nil, implementation: .address("0x80"), relation: nil),
        ])]))
        #expect(text.contains("    virtual /* unnamed */;  // slot 21  0x80\n"))
    }

    @Test("pure and deleted slots print their markers")
    func pureAndDeletedSlotsPrintTheirMarkers() {
        let text = Self.text(Self.widget(tables: [.init(offsetToTop: 0, slots: [
            .init(index: 0, function: Self.draw, implementation: .pureVirtual, relation: nil),
            .init(index: 1, function: nil, implementation: .deletedVirtual, relation: nil),
        ])]))
        #expect(text.contains("virtual draw(int) const = 0;  // slot 0\n"))
        #expect(text.contains("virtual /* unnamed */ = delete;  // slot 1\n"))
    }

    @Test("a secondary table names the base subobject it belongs to")
    func secondaryTableNamesItsSubobject() {
        let text = Self.text(Self.widget(tables: [
            .init(offsetToTop: 0, slots: [.init(index: 0, function: Self.draw, implementation: .address("0x90"), relation: nil)]),
            .init(offsetToTop: -16, subobjectClassName: "ui::Responder", slots: [.init(index: 0, function: .init(name: "respond"), implementation: .imported(installName: "/usr/lib/libui.dylib"), relation: nil)]),
        ]))
        #expect(text.contains("// Virtual functions (secondary vtable for ui::Responder, offset-to-top -16)\n"))
        #expect(text.contains("virtual respond();  // slot 0  imported from /usr/lib/libui.dylib\n"))
    }

    @Test("a return type is printed only when the declaration has one")
    func returnTypePrintedOnlyWhenMangled() {
        let text = Self.text(Self.widget(functions: [
            .init(function: .init(returnType: "int", name: "get<int>", parameters: "()"), addresses: ["0xA0"]),
            .init(function: .init(name: "reset", parameters: "()", qualifiers: ["&&"]), addresses: ["0xB0"]),
        ]))
        #expect(text.contains("    int get<int>();  // 0xA0\n"))
        #expect(text.contains("    reset() &&;  // 0xB0\n"))
        #expect(!text.contains("static"))
        #expect(!text.contains("public:"))
    }

    @Test("without addresses, comments keep slot numbers and relations only")
    func addressCommentsFollowIMPAddressOption() {
        let text = Self.text(Self.widget(
            tables: [.init(offsetToTop: 0, slots: [.init(index: 2, function: Self.draw, implementation: .address("0x50"), relation: .overrides("ui::View"))])],
            functions: [.init(function: .init(name: "reset"), addresses: ["0xB0"])]
        ), showsAddresses: false)
        #expect(!text.contains("0x"))
        #expect(text.contains("// UIKitCore\n"))
        #expect(text.contains("virtual draw(int) const;  // slot 2  overrides ui::View\n"))
        #expect(text.contains("    reset();\n"))
    }

    @Test("a class only run-time type information shows says so")
    func typeInfoOnlyClassSaysSo() {
        var declaration = Self.widget()
        declaration.isRecoveredFromTypeInfoOnly = true
        declaration.hasNonUniqueTypeInfo = true
        let text = Self.text(declaration)
        #expect(text.contains("// Recovered from run-time type information only: no symbol of the image names the class.\n"))
        #expect(text.contains("// Its typeinfo is not unique: each image keeps a copy, compared by name.\n"))
    }

    @Test("a namespace prints its functions, variables and declarations")
    func namespacePrintsFunctionsVariablesAndChildren() {
        var declaration = Printer.NamespaceDeclaration(qualifiedName: "ui", imageName: "UIKitCore")
        declaration.functions = [.init(function: .init(name: "makeWidget", parameters: "(int)"), addresses: ["0xC0"])]
        declaration.variables = [.init(name: "gWidgetCount", addresses: ["0xD0"])]
        declaration.declared = [.init(qualifiedName: "ui::Widget", isClass: true), .init(qualifiedName: "ui::detail", isClass: false)]
        let text = Printer(showsAddresses: true).interface(of: declaration).string
        #expect(text == """
        // UIKitCore
        namespace ui {
            // Functions
            makeWidget(int);  // 0xC0

            // Variables
            gWidgetCount;  // 0xD0

            // Declared here
            class ui::Widget;
            namespace ui::detail {}
        }
        """)
    }

    @Test("the global namespace prints its members without braces")
    func globalNamespacePrintsWithoutBraces() {
        var declaration = Printer.NamespaceDeclaration(qualifiedName: "::", imageName: "libfoo", isGlobal: true)
        declaration.functions = [.init(function: .init(name: "foo"), addresses: ["0xE0"])]
        let text = Printer(showsAddresses: true).interface(of: declaration).string
        #expect(text == "// libfoo\n// Global namespace\n// Functions\nfoo();  // 0xE0\n")
    }

    @Test("an undetermined scope says so")
    func undeterminedScopeSaysSo() {
        var declaration = Printer.NamespaceDeclaration(qualifiedName: "helpers", imageName: "libfoo")
        declaration.isUndetermined = true
        let text = Printer(showsAddresses: true).interface(of: declaration).string
        #expect(text.contains("// No symbol name shows whether this is a namespace or a type.\nnamespace helpers {\n"))
    }

    @Test("type tokens carry the names in full, as the content pane looks them up")
    func typeTokensCarryQualifiedNames() {
        let string = Printer(showsAddresses: true).interface(of: Self.widget(declared: [
            .init(qualifiedName: "ui::Widget::Style", isClass: true),
            .init(qualifiedName: "ui::Widget::detail", isClass: false),
        ]))
        #expect(Self.spans(of: .type(.class, .declaration), in: string) == ["ui::Widget"])
        #expect(Self.spans(of: .type(.class, .name), in: string) == ["ui::View", "ui::Widget::Style"])
        #expect(Self.spans(of: .type(.other, .name), in: string) == ["ui::Widget::detail"])
    }

    @Test("function names are function declarations, variable names member declarations")
    func declarationsCarryTheirSemanticTypes() {
        let string = Printer(showsAddresses: true).interface(of: Self.widget(
            functions: [.init(function: Self.draw, addresses: [])],
            variables: [.init(name: "count", addresses: [])]
        ))
        #expect(Self.spans(of: .function(.declaration), in: string) == ["draw"])
        #expect(Self.spans(of: .member(.declaration), in: string) == ["count"])
        #expect(Self.spans(of: .keyword, in: string).contains("const"))
    }
}
