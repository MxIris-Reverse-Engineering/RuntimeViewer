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

/// The tag the content pane shows after a C-imported type's declaration and how its click works
/// (proposal `c-imported-type-name-spelling` in MachOSwiftSection): the tag holds the name the text
/// does not print, and a click stores the other spelling as the Generation Option.
@Suite("C-imported type name tags", .serialized)
@MainActor
struct CImportedTypeNameTagTests {
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

    private static func tags(of interface: RuntimeObjectInterface, spelling: SwiftGenerationOptions.CImportedTypeNameSpelling) -> [ContentTextViewModel.CImportedTypeNameTag] {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.cImportedTypeNameSpelling = spelling
        let fetchedInterface = ContentTextViewModel.displayedInterface(of: interface, runtimeObject: runtimeObject, options: options)
        return ContentInterface.prepared(from: fetchedInterface).cImportedTypeNameTags
    }

    @Test("Spelling Swift names, the tag holds the C name and offers C names")
    func tagHoldsCNameUnderSwiftSpelling() throws {
        let text = "struct AnyWeakAttribute {}"
        let tags = Self.tags(of: try Self.interface(text: text, declaredName: "AnyWeakAttribute"), spelling: .swiftName)
        #expect(tags == [
            ContentTextViewModel.CImportedTypeNameTag(range: NSRange(location: 7, length: 16), label: "C name", name: "AGWeakAttribute", toolTip: "Show C Names"),
        ])
    }

    @Test("Spelling C names, the tag holds the Swift name and offers Swift names")
    func tagHoldsSwiftNameUnderCSpelling() throws {
        let text = "struct AGWeakAttribute {}"
        let tags = Self.tags(of: try Self.interface(text: text, declaredName: "AGWeakAttribute"), spelling: .cName)
        #expect(tags == [
            ContentTextViewModel.CImportedTypeNameTag(range: NSRange(location: 7, length: 15), label: "Swift name", name: "AnyWeakAttribute", toolTip: "Show Swift Names"),
        ])
    }

    /// The engine counts UTF-8; the text views count UTF-16.
    @Test("A tag's range is in UTF-16 offsets of the text")
    func tagRangeIsInUTF16() throws {
        let text = "// Größe 🧪\nstruct AnyWeakAttribute {}"
        let tags = Self.tags(of: try Self.interface(text: text, declaredName: "AnyWeakAttribute"), spelling: .swiftName)
        let tag = try #require(tags.first)
        #expect((text as NSString).substring(with: tag.range) == "AnyWeakAttribute")
    }

    @Test("An interface without names has no tags")
    func noNamesNoTags() {
        let interface = RuntimeObjectInterface(object: Self.runtimeObject, interfaceString: SemanticString(stringLiteral: "struct AnyWeakAttribute {}"))
        #expect(Self.tags(of: interface, spelling: .swiftName).isEmpty)
    }

    @Test("Clicking a tag stores the other spelling, and clicking it again the first")
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
