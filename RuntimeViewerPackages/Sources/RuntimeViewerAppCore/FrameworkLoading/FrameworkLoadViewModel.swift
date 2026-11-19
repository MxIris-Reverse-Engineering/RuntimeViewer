#if os(macOS)

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// What the Load Frameworks page shows: the framework loading, the one dyld
/// refused with its diagnosis and what the user can do about it, or the
/// instance having gone away.
public enum FrameworkLoadPage: Equatable, Sendable {
    case none
    case loading(title: String, detail: String?)
    case failure(ImageLoadDiagnosisPresentation, FrameworkLoadPageActions)
    case instanceStopped(title: String, detail: String)
}

/// The buttons a failure page offers.
public struct FrameworkLoadPageActions: Equatable, Sendable {
    public var canRetry: Bool
    public var canApplyRemedy: Bool
    public var canChooseHostApplication: Bool
    public var canAddSearchPath: Bool
    /// The page is a sheet, which closes.
    public var canClose: Bool
}

/// The Load Frameworks page, over the document's `FrameworkLoader`: in an
/// empty editor pane of a framework instance's window, where `Route` is the
/// pane's, and as a sheet over the window, where `dismissRoute` closes it.
public final class FrameworkLoadViewModel<Route: Routable>: ViewModel<Route> {
    @Dependency(\.finderClient) private var finderClient

    @RxObserved private(set) var page: FrameworkLoadPage = .none

    private let dismissRoute: Route?

    private let requestHostApplicationRelay = PublishRelay<Void>()

    private let requestSearchPathRelay = PublishRelay<Void>()

    public init(documentState: DocumentState, router: any Router<Route>, dismissRoute: Route?) {
        self.dismissRoute = dismissRoute
        super.init(documentState: documentState, router: router)
        let canClose = dismissRoute != nil
        documentState.frameworkLoader.$state.asObservable()
            .map { Self.page(for: $0, canClose: canClose) }
            .distinctUntilChanged()
            .bind(to: $page)
            .disposed(by: rx.disposeBag)
    }

    public struct Input {
        public let retryClicked: Signal<Void>
        public let remedyClicked: Signal<Void>
        public let chooseHostApplicationClicked: Signal<Void>
        public let addSearchPathClicked: Signal<Void>
        /// The app the user picked in the panel `requestHostApplication` asked for.
        public let hostApplicationChosen: Signal<URL>
        /// The folder the user picked in the panel `requestSearchPath` asked for.
        public let searchPathChosen: Signal<URL>
        public let loadAgainClicked: Signal<Void>
        public let copyDiagnosisClicked: Signal<Void>
        public let showInFinderClicked: Signal<Void>
        public let closeClicked: Signal<Void>

        public init(
            retryClicked: Signal<Void>,
            remedyClicked: Signal<Void>,
            chooseHostApplicationClicked: Signal<Void>,
            addSearchPathClicked: Signal<Void>,
            hostApplicationChosen: Signal<URL>,
            searchPathChosen: Signal<URL>,
            loadAgainClicked: Signal<Void>,
            copyDiagnosisClicked: Signal<Void>,
            showInFinderClicked: Signal<Void>,
            closeClicked: Signal<Void>
        ) {
            self.retryClicked = retryClicked
            self.remedyClicked = remedyClicked
            self.chooseHostApplicationClicked = chooseHostApplicationClicked
            self.addSearchPathClicked = addSearchPathClicked
            self.hostApplicationChosen = hostApplicationChosen
            self.searchPathChosen = searchPathChosen
            self.loadAgainClicked = loadAgainClicked
            self.copyDiagnosisClicked = copyDiagnosisClicked
            self.showInFinderClicked = showInFinderClicked
            self.closeClicked = closeClicked
        }
    }

    public struct Output {
        public let page: Driver<FrameworkLoadPage>
        /// Open a panel for the app the frameworks belong to.
        public let requestHostApplication: Signal<Void>
        /// Open a panel for a folder to search.
        public let requestSearchPath: Signal<Void>
    }

    public func transform(_ input: Input) -> Output {
        let frameworkLoader = documentState.frameworkLoader
        input.retryClicked.emitOnNext {
            Task { await frameworkLoader.retry() }
        }
        .disposed(by: rx.disposeBag)
        input.remedyClicked.emitOnNext {
            Task { await frameworkLoader.applyRemedy() }
        }
        .disposed(by: rx.disposeBag)
        input.chooseHostApplicationClicked.emit(to: requestHostApplicationRelay).disposed(by: rx.disposeBag)
        input.addSearchPathClicked.emit(to: requestSearchPathRelay).disposed(by: rx.disposeBag)
        input.hostApplicationChosen.emitOnNext { applicationURL in
            Task { await frameworkLoader.retry(hostedBy: applicationURL) }
        }
        .disposed(by: rx.disposeBag)
        input.searchPathChosen.emitOnNext { directoryURL in
            Task { await frameworkLoader.retry(searching: directoryURL) }
        }
        .disposed(by: rx.disposeBag)
        input.loadAgainClicked.emitOnNext {
            Task { await frameworkLoader.loadAgain() }
        }
        .disposed(by: rx.disposeBag)
        input.copyDiagnosisClicked.emitOnNext { [weak self] in
            guard let self, case .failure(let presentation, _) = page else { return }
            pasteboardClient.copyString(presentation.copyText)
        }
        .disposed(by: rx.disposeBag)
        input.showInFinderClicked.emitOnNext { [weak self] in
            guard let self, case .failure(let presentation, _) = page else { return }
            finderClient.revealFile(URL(fileURLWithPath: presentation.imagePath))
        }
        .disposed(by: rx.disposeBag)
        input.closeClicked.emitOnNext { [weak self] in
            guard let self, let dismissRoute else { return }
            router.trigger(dismissRoute)
        }
        .disposed(by: rx.disposeBag)
        // A sheet goes away once the load it showed went through.
        $page.asObservable()
            .skip(1)
            .filter { $0 == .none }
            .subscribeOnNext { [weak self] _ in
                guard let self, let dismissRoute else { return }
                router.trigger(dismissRoute)
            }
            .disposed(by: rx.disposeBag)
        return Output(
            page: $page.asDriver(),
            requestHostApplication: requestHostApplicationRelay.asSignal(),
            requestSearchPath: requestSearchPathRelay.asSignal()
        )
    }

    static func page(for state: FrameworkLoadState, canClose: Bool) -> FrameworkLoadPage {
        switch state {
        case .idle:
            return .none
        case .loading(let progress):
            let detail = progress.count > 1 ? "\(progress.position) of \(progress.count)" : nil
            return .loading(title: "Loading \(progress.frameworkURL.lastPathComponent)…", detail: detail)
        case .failed(let failure):
            let presentation = ImageLoadDiagnosisPresentation(diagnosis: failure.diagnosis, frameworkName: failure.frameworkURL.lastPathComponent)
            let actions = FrameworkLoadPageActions(
                canRetry: failure.offersRemedies,
                canApplyRemedy: failure.offersRemedies && failure.diagnosis.remedy != nil,
                canChooseHostApplication: failure.offersRemedies,
                canAddSearchPath: failure.offersRemedies,
                canClose: canClose
            )
            return .failure(presentation, actions)
        case .instanceStopped(let interruption):
            let detail = if let interruptedFrameworkURL = interruption.interruptedFrameworkURL {
                "It stopped while loading \(interruptedFrameworkURL.lastPathComponent), most likely in that framework's own code. A new instance is ready, with nothing loaded."
            } else {
                "The frameworks loaded into it are gone. A new instance is ready, with nothing loaded."
            }
            return .instanceStopped(title: "The instance stopped", detail: detail)
        }
    }
}

#endif
