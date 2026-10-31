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

    public let errorRelay = PublishRelay<Error>()

    package let _commonLoading = ActivityIndicator()

    open var commonLoading: Driver<Bool> {
        _commonLoading.asDriver()
    }

    open var delayedLoading: Driver<Bool> {
        _commonLoading
            .distinctUntilChanged()
            .flatMapLatest { isLoading -> Driver<Bool> in
                if isLoading {
                    // If loading starts, return a sequence that emits 'true' after a delay.
                    // If 'isLoading' becomes false before the delay finishes,
                    // flatMapLatest will dispose this subscription, cancelling the 'true' emission.
                    return Driver.just(true)
                        .delay(.milliseconds(100))
                } else {
                    // If loading ends, emit 'false' immediately to hide the spinner.
                    return Driver.just(false)
                }
            }
    }

    public init(documentState: DocumentState, router: any Router<Route>) {
        self.documentState = documentState
        self.router = router
    }

    /// The generation options a single-object interface fetch should use
    /// right now: the stored options merged with the live transformer
    /// configuration, exactly as the content pipeline's fetch half merges
    /// them. Every fetch that should share a `RuntimeInterfaceCache` entry
    /// with the content pane must use these options so the cache keys line
    /// up (and so exported text matches what the pane displays).
    public var currentMergedGenerationOptions: RuntimeObjectInterface.GenerationOptions {
        var mergedOptions = appDefaults.options
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        mergedOptions.transformer = settings.transformer
        mergedOptions.marksCommentStructure = settings.editor.drawsCommentTags
        #else
        mergedOptions.transformer = .init()
        #endif
        return mergedOptions
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension Settings.Editor {
    /// Whether the content pane draws comments as tags, and so asks the
    /// engine what each comment is: only Xcode's editor does, and only while
    /// Comment Tags is on. Asked for even when the editor then fails to load —
    /// the text is the same, only the structure goes unused.
    var drawsCommentTags: Bool {
        usesSourceEditor && showsCommentTags
    }
}
#endif

@MainActor
open class CellViewModel: NSObject {}
