import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import MemberwiseInit

/// The popover a sidebar row's `Private` tag opens: every private declaration the row's name runs
/// through (`RuntimeObject.privateDeclarations`), with its discriminator and the source file it was
/// derived from.
///
/// The source files are recovered by the engine, from the names of the row's image
/// (`RuntimeEngine.privateDeclarationSourceFiles(forDiscriminators:inImage:)`); this only shows them.
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

    /// The source files of the row's discriminators, as one value: rows can never show a
    /// placeholder next to a recovered name.
    enum SourceFilesState {
        case pending
        case recovering
        case recovered([String: RuntimePrivateDeclarationSourceFile])
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
            .recovered(try await runtimeEngine.privateDeclarationSourceFiles(forDiscriminators: discriminators, inImage: imagePath))
        }
        .withLoadingPlaceholder(
            .recovering,
            appearsAfter: LoadingPlaceholderTiming.appearsAfter,
            staysAtLeast: LoadingPlaceholderTiming.staysAtLeast
        )
        // An engine that cannot answer — one built before the command
        // existed, or one that lost its connection — recovers nothing: every
        // declaration still shows its discriminator.
        .catchAndReturn(.recovered([:]))
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
        case .recovered(let sourceFileByDiscriminator):
            if let sourceFile = sourceFileByDiscriminator[discriminator] {
                .recovered(fileName: sourceFile.fileName, moduleName: sourceFile.moduleName, isSynthesized: sourceFile.isSynthesized)
            } else {
                .unrecovered
            }
        }
    }
}
