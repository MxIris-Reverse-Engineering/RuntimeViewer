import Foundation
import Dependencies
import RxSwift
@testable import RuntimeViewerCore
@testable import RuntimeViewerSettings
import RuntimeViewerArchitectures
import Semantic
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// What the content pane says beside a C-imported type's declaration and how its switch works
/// (proposal `c-imported-type-name-spelling` in MachOSwiftSection): the note names the spelling the
/// text does not print, and choosing it stores the other spelling as the Generation Option.
@Suite("C-imported type name notes", .serialized)
@MainActor
struct CImportedTypeNameNoteTests {
    private static let runtimeObject = RuntimeObject(
        name: "AGWeakAttribute",
        displayName: "AGWeakAttribute",
        kind: .swift(.type(.struct)),
        imagePath: "/System/Library/PrivateFrameworks/AttributeGraph.framework/Versions/A/AttributeGraph",
        children: [],
        properties: []
    )

    private static func interface(text: String, declaredName: String, swiftName: String = "AnyWeakAttribute", cName: String = "AGWeakAttribute") throws -> RuntimeObjectInterface {
        let declaredNameStart = try #require(text.range(of: declaredName)).lowerBound
        let utf8Start = text.utf8.distance(from: text.utf8.startIndex, to: declaredNameStart)
        return RuntimeObjectInterface(
            object: runtimeObject,
            interfaceString: SemanticString(stringLiteral: text),
            cImportedTypeNames: [
                RuntimeInterfaceCImportedTypeName(nameUTF8Range: utf8Start ..< utf8Start + declaredName.utf8.count, swiftName: swiftName, cName: cName),
            ]
        )
    }

    private static func notes(of interface: RuntimeObjectInterface, spelling: SwiftGenerationOptions.CImportedTypeNameSpelling) -> [ContentTextViewModel.CImportedTypeNameNote] {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.cImportedTypeNameSpelling = spelling
        let fetchedInterface = ContentTextViewModel.displayedInterface(of: interface, runtimeObject: runtimeObject, options: options)
        return ContentInterface.prepared(from: fetchedInterface).cImportedTypeNameNotes
    }

    @Test("Spelling Swift names, the note names the C declaration and offers C names")
    func notesNameCDeclarationUnderSwiftSpelling() throws {
        let text = "struct AnyWeakAttribute {}"
        let notes = Self.notes(of: try Self.interface(text: text, declaredName: "AnyWeakAttribute"), spelling: .swiftName)
        #expect(notes == [
            ContentTextViewModel.CImportedTypeNameNote(range: NSRange(location: 7, length: 16), message: "Imported from C as AGWeakAttribute", actionTitle: "Show C Names"),
        ])
    }

    @Test("Spelling C names, the note names the Swift type and offers Swift names")
    func notesNameSwiftTypeUnderCSpelling() throws {
        let text = "struct AGWeakAttribute {}"
        let notes = Self.notes(of: try Self.interface(text: text, declaredName: "AGWeakAttribute"), spelling: .cName)
        #expect(notes == [
            ContentTextViewModel.CImportedTypeNameNote(range: NSRange(location: 7, length: 15), message: "Imported to Swift as AnyWeakAttribute", actionTitle: "Show Swift Names"),
        ])
    }

    /// The engine counts UTF-8; the text views count UTF-16.
    @Test("A note's range is in UTF-16 offsets of the text")
    func noteRangeIsInUTF16() throws {
        let text = "// Größe 🧪\nstruct AnyWeakAttribute {}"
        let notes = Self.notes(of: try Self.interface(text: text, declaredName: "AnyWeakAttribute"), spelling: .swiftName)
        let note = try #require(notes.first)
        #expect((text as NSString).substring(with: note.range) == "AnyWeakAttribute")
    }

    @Test("An interface without names has no notes")
    func noNamesNoNotes() {
        let interface = RuntimeObjectInterface(object: Self.runtimeObject, interfaceString: SemanticString(stringLiteral: "struct AnyWeakAttribute {}"))
        #expect(Self.notes(of: interface, spelling: .swiftName).isEmpty)
    }

    @Test("Choosing a note's switch stores the other spelling, and choosing it again the first")
    func togglingFlipsStoredSpelling() throws {
        let appDefaults = AppDefaults.isolated()
        let toggledRelay = PublishRelay<Void>()
        let router = MockRouter<ContentRoute>()
        // The live context, with this test's own store: the view model writes the spelling there.
        let viewModel = withDependencies {
            $0.context = .live
            $0.settings = SettingsAccess.preview
            $0.appDefaults = appDefaults
        } operation: {
            ContentTextViewModel(
                runtimeObject: Self.runtimeObject,
                documentState: DocumentState(),
                router: router,
                interfaceProvider: { runtimeObject, _ in
                    RuntimeObjectInterface(object: runtimeObject, interfaceString: SemanticString(stringLiteral: "struct AnyWeakAttribute {}"))
                }
            )
        }
        _ = viewModel.transform(ContentTextViewModel.Input(
            runtimeObjectClicked: .empty(),
            runtimeObjectOpenedInNewTab: .empty(),
            interfaceDisplayed: .empty(),
            cImportedTypeNameSpellingToggled: toggledRelay.asSignal()
        ))
        #expect(appDefaults.options.swiftInterfaceOptions.cImportedTypeNameSpelling == .swiftName)
        toggledRelay.accept(())
        #expect(appDefaults.options.swiftInterfaceOptions.cImportedTypeNameSpelling == .cName)
        toggledRelay.accept(())
        #expect(appDefaults.options.swiftInterfaceOptions.cImportedTypeNameSpelling == .swiftName)
        // The internal switch the content pane merges in per request is never stored.
        #expect(!appDefaults.options.marksCImportedTypeNames)
        withExtendedLifetime(viewModel) {}
        withExtendedLifetime(router) {}
    }
}
