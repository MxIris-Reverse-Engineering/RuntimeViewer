import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// The popover a sidebar row's `Private` tag opens: every private declaration the row's name runs
/// through (`RuntimeObject.privateDeclarations`), with its discriminator and the source file it was
/// derived from.
///
/// The source files are recovered from every name in the row's image
/// (`RuntimePrivateDiscriminatorSourceFiles`) off the main thread. The coordinator hands over the
/// objects the image's list already holds; when it holds none, they are asked of the engine.
public final class PrivateDeclarationViewModel: ViewModel<SidebarRuntimeObjectRoute> {
    public struct Declaration: Equatable {
        /// The declaration's name; `nil` when the demangled name gives it none.
        public let name: String?

        /// The discriminator, leading underscore included.
        public let discriminator: String

        public let sourceFile: SourceFile
    }

    public enum SourceFile: Equatable {
        /// Recovery has not finished and has not yet taken long enough to say so.
        case pending
        /// Recovery is taking long enough to show that it is under way.
        case recovering
        case recovered(fileName: String, moduleName: String, isSynthesized: Bool)
        /// No name in the image produced the discriminator.
        case unrecovered
    }

    /// The source files of the image's discriminators, as one value: rows can never show a
    /// placeholder next to a recovered name.
    enum SourceFilesState {
        case pending
        case recovering
        case recovered(RuntimePrivateDiscriminatorSourceFiles)
    }

    @MemberwiseInit(.public)
    public struct Input {}

    public struct Output {
        public let displayName: Driver<String>
        public let declarations: Driver<[Declaration]>
    }

    private let runtimeObject: RuntimeObject

    @RxObserved
    private(set) var sourceFilesState: SourceFilesState = .pending

    public init(
        runtimeObject: RuntimeObject,
        imageRuntimeObjects: [RuntimeObject],
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.runtimeObject = runtimeObject
        super.init(documentState: documentState, router: router)

        // Captures the engine, not `self`: the task outlives disposal, since
        // cancellation is only cooperative.
        let imagePath = runtimeObject.imagePath
        let discriminators = runtimeObject.privateDeclarations.map(\.discriminator)
        let runtimeEngine = documentState.runtimeEngine
        Observable<SourceFilesState>.async {
            let runtimeObjects = imageRuntimeObjects.isEmpty ? try await runtimeEngine.objects(in: imagePath) : imageRuntimeObjects
            return .recovered(await PrivateDeclarationViewModel.recoverSourceFiles(of: discriminators, imagePath: imagePath, runtimeObjects: runtimeObjects))
        }
        .withLoadingPlaceholder(
            .recovering,
            appearsAfter: LoadingPlaceholderTiming.appearsAfter,
            staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
        )
        // An image whose objects cannot be listed recovers nothing: every
        // declaration still shows its discriminator.
        .catchAndReturn(.recovered(RuntimePrivateDiscriminatorSourceFiles(recovering: [], imagePath: imagePath, runtimeObjects: [])))
        .observeOnMainScheduler()
        .bind(to: $sourceFilesState)
        .disposed(by: rx.disposeBag)
    }

    public func transform(_ input: Input) -> Output {
        let privateDeclarations = runtimeObject.privateDeclarations
        return Output(
            displayName: .just(runtimeObject.displayName),
            declarations: $sourceFilesState.asDriver().map { sourceFilesState in
                privateDeclarations.map { privateDeclaration in
                    Declaration(
                        name: privateDeclaration.name,
                        discriminator: privateDeclaration.discriminator,
                        sourceFile: Self.sourceFile(of: privateDeclaration.discriminator, in: sourceFilesState)
                    )
                }
            }
        )
    }

    private static func sourceFile(of discriminator: String, in sourceFilesState: SourceFilesState) -> SourceFile {
        switch sourceFilesState {
        case .pending:
            .pending
        case .recovering:
            .recovering
        case .recovered(let sourceFiles):
            if let sourceFile = sourceFiles.sourceFile(forDiscriminator: discriminator) {
                .recovered(fileName: sourceFile.fileName, moduleName: sourceFile.moduleName, isSynthesized: sourceFile.isSynthesized)
            } else {
                .unrecovered
            }
        }
    }

    /// Candidates from every name in the image, nested types included, hashed
    /// against this row's discriminators until all are found. A discriminator
    /// nothing produces runs through every candidate — three to four seconds for
    /// SwiftUICore in a debug build — so never on the main actor.
    @concurrent
    private nonisolated static func recoverSourceFiles(of discriminators: [String], imagePath: String, runtimeObjects: [RuntimeObject]) async -> RuntimePrivateDiscriminatorSourceFiles {
        RuntimePrivateDiscriminatorSourceFiles(recovering: discriminators, imagePath: imagePath, runtimeObjects: runtimeObjects)
    }
}
