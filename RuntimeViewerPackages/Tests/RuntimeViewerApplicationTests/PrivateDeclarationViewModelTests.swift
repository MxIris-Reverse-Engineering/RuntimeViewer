import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The popover a sidebar row's `Private` tag opens: the row's private declarations, each with its
/// discriminator and the source file the engine recovers from the names of the row's image
/// (`RuntimeEngine.privateDeclarationSourceFiles(forDiscriminators:inImage:)`; the search itself is
/// MachOSwiftSection's, and is tested there).
@Suite("PrivateDeclarationViewModel")
@MainActor
struct PrivateDeclarationViewModelTests {
    private let router = MockRouter<SidebarRuntimeObjectRoute>()

    @Test("each private declaration is listed with its discriminator and the source file the engine recovers")
    func declarationCarriesRecoveredSourceFile() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let jsonEncoder = try await Self.foundationJSONEncoder(in: engine)
        let (viewModel, output) = makeViewModel(for: jsonEncoder, runtimeEngine: engine)
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, timeout: 60, where: Self.isSettled)
        #expect(declarations == [
            .init(
                name: "__JSONEncoder",
                discriminator: "_12768CA107A31EF2DCE034FD75B541C9",
                sourceFile: .recovered(fileName: "JSONEncoder.swift", moduleName: "Foundation", isSynthesized: false)
            ),
        ])
        #expect(try await nextValue(from: output.displayName) == "Foundation.__JSONEncoder")
    }

    /// No file name hashes to all zeros: the engine runs through every candidate of Foundation and
    /// comes back empty-handed.
    @Test("a discriminator no name in the image produces is listed unrecovered")
    func unproducedDiscriminatorIsUnrecovered() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.objects(in: TestImages.foundation)
        let madeUpType = Fixtures.runtimeObject(
            name: "Foundation.MadeUp",
            kind: .swift(.type(.struct)),
            imagePath: TestImages.foundation,
            privateDeclarations: [.init(name: "MadeUp", discriminator: "_00000000000000000000000000000000")]
        )
        let (viewModel, output) = makeViewModel(for: madeUpType, runtimeEngine: engine)
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, timeout: 60, where: Self.isSettled)
        #expect(declarations == [
            .init(name: "MadeUp", discriminator: "_00000000000000000000000000000000", sourceFile: .unrecovered),
        ])
    }

    @Test("an engine that cannot answer leaves every declaration unrecovered, its discriminator still shown")
    func unansweredEngineLeavesDeclarationsUnrecovered() async throws {
        let privateType = Fixtures.runtimeObject(
            name: "SwiftUI.EnabledKey",
            kind: .swift(.type(.struct)),
            imagePath: "/System/Library/Frameworks/SwiftUICore.framework/Versions/A/SwiftUICore",
            privateDeclarations: [.init(name: "EnabledKey", discriminator: "_09CE35833F3876FE3A3A46977D61FC64")]
        )
        let (viewModel, output) = makeViewModel(for: privateType, runtimeEngine: TestRuntimeEngine.makeUnreachable())
        defer { withExtendedLifetime(viewModel) {} }

        let declarations = try await nextValue(from: output.declarations, where: Self.isSettled)
        #expect(declarations == [
            .init(name: "EnabledKey", discriminator: "_09CE35833F3876FE3A3A46977D61FC64", sourceFile: .unrecovered),
        ])
    }

    // MARK: - Helpers

    private static func foundationJSONEncoder(in engine: RuntimeEngine) async throws -> RuntimeObject {
        let foundationObjects = try await engine.objects(in: TestImages.foundation)
        return try #require(
            foundationObjects.first { $0.privateDeclarations == [.init(name: "__JSONEncoder", discriminator: "_12768CA107A31EF2DCE034FD75B541C9")] },
            "Foundation has no __JSONEncoder with the discriminator macOS 26 and 27 give it"
        )
    }

    private func makeViewModel(
        for runtimeObject: RuntimeObject,
        runtimeEngine: RuntimeEngine
    ) -> (PrivateDeclarationViewModel, PrivateDeclarationViewModel.Output) {
        let environment = ViewModelTestEnvironment(runtimeEngine: runtimeEngine)
        let viewModel = environment.make {
            PrivateDeclarationViewModel(
                runtimeObject: runtimeObject,
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
}
