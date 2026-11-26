import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerSettings

@MainActor
open class ViewModel<Route: Routable>: NSObject, ViewModelProtocol {
    public let documentState: DocumentState

    public unowned let router: any Router<Route>

    @Dependency(\.appDefaults)
    public var appDefaults

    #if os(macOS)
    @Dependency(\.appRouter)
    public var appRouter
    #endif

    @Dependency(\.settings)
    public var settings

    /// Where the context menus' copy commands put their text; see
    /// `perform(_:on:)`.
    @Dependency(\.pasteboardClient)
    public var pasteboardClient

    public let errorRelay = PublishRelay<Error>()

    package let _commonLoading = ActivityIndicator()

    open var commonLoading: Driver<Bool> {
        _commonLoading.asDriver()
    }

    open var delayedLoading: Driver<Bool> {
        _commonLoading.asDriver().delayingTrue(by: .milliseconds(100))
    }

    public init(documentState: DocumentState, router: any Router<Route>) {
        self.documentState = documentState
        self.router = router
    }

    /// The generation options a single-object interface fetch of `runtimeObject` should use right
    /// now: the effective Generation Options of the image it is in, merged with the live transformer
    /// configuration exactly as the content pipeline's fetch half merges them. Every fetch that
    /// should share a `RuntimeInterfaceCache` entry with the content pane must use these options so
    /// the cache keys line up (and so exported text matches what the pane displays).
    public func mergedGenerationOptions(for runtimeObject: RuntimeObject) -> RuntimeObjectInterface.GenerationOptions {
        mergedGenerationOptions(forImageAt: runtimeObject.imagePath)
    }

    /// ``mergedGenerationOptions(for:)`` for an object in the image at `imagePath` of the document's
    /// engine.
    public func mergedGenerationOptions(forImageAt imagePath: String) -> RuntimeObjectInterface.GenerationOptions {
        settings.mergedGenerationOptions(forImageAt: imagePath, in: documentState.runtimeEngine)
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension Settings.Editor {
    /// Whether the content pane draws comments as tags, and so asks the
    /// engine what each comment is: only SourceEditor does, in a build that
    /// can run it, and only while Comment Tags is on. Asked for even when the
    /// editor then fails to load — the text is the same, only the structure
    /// goes unused.
    var drawsCommentTags: Bool {
        guard case .available = SourceEditorFrameworks.availability else { return false }
        return showsCommentTags
    }

    /// Whether the content pane can show an attached macro's expansion below its attribute, the way
    /// Xcode shows an expanded macro, and so asks the engine for the expansions: only SourceEditor
    /// can, in a build that can run it.
    var showsMacroExpansionsInline: Bool {
        guard case .available = SourceEditorFrameworks.availability else { return false }
        return true
    }

    /// Whether the content pane can show after a C-imported type's declaration a tag with its other
    /// name that switches to it, and so asks the engine for the names: only SourceEditor can, in a
    /// build that can run it.
    var showsCImportedTypeNameTags: Bool {
        guard case .available = SourceEditorFrameworks.availability else { return false }
        return true
    }
}
#endif

@MainActor
open class CellViewModel: NSObject {}

extension SharedSequence where SharingStrategy == DriverSharingStrategy, Element == Bool {
    /// A loading state as a spinner shows it: `true` only once the work has lasted `delay`, so work
    /// faster than that shows nothing, and `false` at once when it ends. Shared by the view models'
    /// `delayedLoading` and the content pane's renderer (RuntimeViewerAppUI's `ContentTextRenderer`).
    public func delayingTrue(by delay: RxTimeInterval) -> Driver<Bool> {
        distinctUntilChanged()
            .flatMapLatest { isLoading -> Driver<Bool> in
                if isLoading {
                    // A loading that ends before the delay disposes this, so its `true` never comes.
                    return Driver.just(true).delay(delay)
                } else {
                    return Driver.just(false)
                }
            }
    }
}
