import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The popover a sidebar row's `Private` tag opens: the row's private declarations, each with its
/// discriminator and the source file recovered from the names in the row's image. Expected file names were checked with `md5 -s` (see
/// `RuntimePrivateDiscriminatorSourceFilesTests` in RuntimeViewerCore).
@Suite("PrivateDeclarationViewModel")
@MainActor
struct PrivateDeclarationViewModelTests {
    private static let swiftUICorePath = "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore"

    private let router = MockRouter<SidebarRuntimeObjectRoute>()

    @Test("each private declaration is listed with its discriminator and the source file the image's names recover")
    func declarationCarriesRecoveredSourceFile() async throws {
        let privateType = Self.object("SwiftUI.ResetDeltaModifier", privateDeclarations: [.init(name: "ResetDeltaModifier", discriminator: "_C38EF38637B6130AEFD462CBD5EAC727")])
        let (viewModel, output) = makeViewModel(
            for: privateType,
            imageRuntimeObjects: [privateType, Self.object("SwiftUI._ViewInputs")],
            // Never asked: the objects are handed over.
            runtimeEngine: TestRuntimeEngine.makeUnreachable()
        )
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, where: Self.isSettled)
        #expect(declarations == [
            .init(
                name: "ResetDeltaModifier",
                discriminator: "_C38EF38637B6130AEFD462CBD5EAC727",
                sourceFile: .recovered(fileName: "ViewInputs.swift", moduleName: "SwiftUICore", isSynthesized: false)
            ),
        ])
        #expect(try await nextValue(from: output.displayName) == "SwiftUI.ResetDeltaModifier")
    }

    @Test("a discriminator no name in the image produces is listed unrecovered")
    func unproducedDiscriminatorIsUnrecovered() async throws {
        let privateType = Self.object("SwiftUI.NearestScrollableAxesEnvironmentKey", privateDeclarations: [.init(name: "NearestScrollableAxesEnvironmentKey", discriminator: "_70EED0686586E4A728468B96DBF4A6DF")])
        let (viewModel, output) = makeViewModel(for: privateType, imageRuntimeObjects: [privateType], runtimeEngine: TestRuntimeEngine.makeUnreachable())
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, where: Self.isSettled)
        #expect(declarations == [
            .init(name: "NearestScrollableAxesEnvironmentKey", discriminator: "_70EED0686586E4A728468B96DBF4A6DF", sourceFile: .unrecovered),
        ])
    }

    @Test("with no objects handed over, the image's names are asked of the engine")
    func namesAreAskedOfTheEngine() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let foundationObjects = try await engine.objects(in: TestImages.foundation)
        let jsonEncoder = try #require(
            foundationObjects.first { $0.privateDeclarations == [.init(name: "__JSONEncoder", discriminator: "_12768CA107A31EF2DCE034FD75B541C9")] },
            "Foundation has no __JSONEncoder with the discriminator macOS 26 and 27 give it"
        )
        let (viewModel, output) = makeViewModel(for: jsonEncoder, imageRuntimeObjects: [], runtimeEngine: engine)
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, timeout: 60, where: Self.isSettled)
        #expect(declarations.map(\.sourceFile) == [.recovered(fileName: "JSONEncoder.swift", moduleName: "Foundation", isSynthesized: false)])
    }

    // MARK: - Helpers

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        imageRuntimeObjects: [RuntimeObject],
        runtimeEngine: RuntimeEngine
    ) -> (PrivateDeclarationViewModel, PrivateDeclarationViewModel.Output) {
        let environment = ViewModelTestEnvironment(runtimeEngine: runtimeEngine)
        let viewModel = environment.make {
            PrivateDeclarationViewModel(
                runtimeObject: runtimeObject,
                imageRuntimeObjects: imageRuntimeObjects,
                documentState: environment.documentState,
                router: router
            )
        }
        return (viewModel, viewModel.transform(PrivateDeclarationViewModel.Input()))
    }

    private static func isSettled(_ declarations: [PrivateDeclarationViewModel.Declaration]) -> Bool {
        declarations.allSatisfy { declaration in
            switch declaration.sourceFile {
            case .pending, .recovering:
                false
            case .recovered, .unrecovered:
                true
            }
        }
    }

    private static func object(_ displayName: String, privateDeclarations: [RuntimePrivateDeclaration] = []) -> RuntimeObject {
        Fixtures.runtimeObject(name: displayName, kind: .swift(.type(.struct)), imagePath: swiftUICorePath, privateDeclarations: privateDeclarations)
    }
}
