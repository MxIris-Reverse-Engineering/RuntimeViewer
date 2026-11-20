import Foundation
import Combine
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Loads the frameworks a window asks for into its engine, one after another,
/// and keeps what the window shows about it: the framework loading, the one
/// dyld refused with why, or the instance having gone away.
///
/// One per document. On a framework instance — a Load Frameworks on My Mac —
/// a refusal offers remedies: loading first what the framework needs, found
/// in the app it belongs to or in a host app or folder the user names, which
/// the loader keeps until the window closes. On any other engine the frameworks
/// go into that engine's process as they always did, and a refusal is only
/// diagnosed. Every load is the user's own, which the Report's Manual Loading
/// lists.
@Loggable
@MainActor
public final class FrameworkLoader {
    /// How an image reaches the engine, how a refusal is retraced, and how
    /// long Load Again waits for the instance to be back. Test seam: a test
    /// scripts all three.
    struct ImageLoading: Sendable {
        var loadImage: @MainActor @Sendable (RuntimeEngine, String) async throws -> Void
        var diagnoseImageLoad: @MainActor @Sendable (RuntimeEngine, RuntimeImageLoadDiagnosis, String?, [String]) async throws -> RuntimeImageLoadDiagnosis
        var waitUntilReady: @MainActor @Sendable (RuntimeEngine) async -> Void

        static let live = ImageLoading(
            loadImage: { engine, imagePath in
                try await engine.loadImageInServingProcess(at: imagePath)
            },
            diagnoseImageLoad: { engine, diagnosis, hostApplicationPath, searchPaths in
                try await engine.diagnoseImageLoad(
                    at: diagnosis.imagePath,
                    dyldMessage: diagnosis.dyldMessage,
                    hostApplicationPath: hostApplicationPath,
                    searchPaths: searchPaths
                )
            },
            waitUntilReady: { engine in
                let deadline = ContinuousClock.now + .seconds(30)
                while !engine.state.isReady, ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        )
    }

    enum LoadError: Error, LocalizedError {
        case noExecutable(URL)

        var errorDescription: String? {
            switch self {
            case .noExecutable(let url):
                "\(url.lastPathComponent) has no executable to load."
            }
        }
    }

    @RxObserved
    public private(set) var state: FrameworkLoadState = .idle

    /// Whether the window's empty editor panes show the loading, failure or
    /// stopped page: on a framework instance, for a request made while the
    /// window showed nothing, and always once the instance went away — the
    /// window then starts over with nothing open. Otherwise a failure is shown
    /// in a sheet (`MainRoute.frameworkLoadFailure`).
    @RxObserved
    public private(set) var showsPageInEmptyPanes: Bool = false

    /// The app the user named for the window's frameworks, or the one a remedy
    /// loaded from; the next refusal in the window is retraced with it.
    public private(set) var hostApplicationURL: URL?

    /// The folders the user added for the window's frameworks.
    public private(set) var searchDirectoryURLs: [URL] = []

    var imageLoading = ImageLoading.live

    private unowned let documentState: DocumentState

    /// Every framework the window asked for, for loading again in a new instance.
    private var requestedFrameworkURLs: [URL] = []

    /// Whether the request now in hand began while the window showed nothing.
    private var presentsInEditorArea = false

    private var followedEngine: ObjectIdentifier?

    private var followedEngineWasReady = false

    private var engineStateSubscription: AnyCancellable?

    init(documentState: DocumentState) {
        self.documentState = documentState
    }

    // MARK: - Loading

    /// Loads `frameworkURLs` into the window's engine, in order, stopping at
    /// the first one refused.
    public func load(frameworksAt frameworkURLs: [URL]) async {
        guard !frameworkURLs.isEmpty else { return }
        let engine = documentState.runtimeEngine
        presentsInEditorArea = documentState.editorArea.hasShownNothing
        for frameworkURL in frameworkURLs where !requestedFrameworkURLs.contains(frameworkURL) {
            requestedFrameworkURLs.append(frameworkURL)
        }
        followInstance(engine)
        // A window opens on a new instance at once; until the instance answers, a request fails
        // rather than being answered here, so the first load waits for it, its page up meanwhile.
        if Self.isFrameworkInstance(engine), !engine.state.isReady {
            setState(.loading(.init(frameworkURL: frameworkURLs[0], position: 1, count: frameworkURLs.count)))
            await imageLoading.waitUntilReady(engine)
            followedEngineWasReady = engine.state.isReady
        }
        await loadSequence(frameworkURLs, on: engine)
    }

    /// Tries the refused framework again, then the ones after it.
    public func retry() async {
        guard case .failed(let failure) = state else { return }
        await loadSequence([failure.frameworkURL] + failure.remainingFrameworkURLs, on: documentState.runtimeEngine)
    }

    /// Loads what the diagnosis says to load first, dependencies before
    /// dependents, then tries the refused framework again.
    public func applyRemedy() async {
        guard case .failed(let failure) = state, failure.offersRemedies, let remedy = failure.diagnosis.remedy else { return }
        let engine = documentState.runtimeEngine
        if let hostApplicationPath = remedy.hostApplicationPath {
            hostApplicationURL = URL(fileURLWithPath: hostApplicationPath)
        }
        let pendingFrameworkURLs = [failure.frameworkURL] + failure.remainingFrameworkURLs
        for (index, imagePath) in remedy.imagePathsToLoadFirst.enumerated() {
            let imageURL = URL(fileURLWithPath: imagePath)
            setState(.loading(.init(frameworkURL: imageURL, position: index + 1, count: remedy.imagePathsToLoadFirst.count)))
            switch await loadImage(at: imagePath, on: engine) {
            case .loaded:
                continue
            case .refused(let error):
                setState(.failed(await diagnosedFailure(for: imageURL, imagePath: imagePath, error: error, remainingFrameworkURLs: pendingFrameworkURLs, on: engine)))
                return
            case .instanceStopped:
                setState(.instanceStopped(.init(frameworkURLs: requestedFrameworkURLs, interruptedFrameworkURL: imageURL)))
                return
            }
        }
        await loadSequence(pendingFrameworkURLs, on: engine)
    }

    /// Retraces the refusal as if the app at `applicationURL` were the main
    /// executable, and loads what that finds first.
    public func retry(hostedBy applicationURL: URL) async {
        hostApplicationURL = applicationURL
        await diagnoseAgainAndApplyRemedy()
    }

    /// Retraces the refusal with `directoryURL` searched after the rpaths, and
    /// loads what that finds first.
    public func retry(searching directoryURL: URL) async {
        if !searchDirectoryURLs.contains(directoryURL) {
            searchDirectoryURLs.append(directoryURL)
        }
        await diagnoseAgainAndApplyRemedy()
    }

    /// Loads every framework the window asked for again, in the new instance
    /// its connection came back to.
    public func loadAgain() async {
        guard case .instanceStopped(let interruption) = state, let firstFrameworkURL = interruption.frameworkURLs.first else { return }
        let engine = documentState.runtimeEngine
        setState(.loading(.init(frameworkURL: firstFrameworkURL, position: 1, count: interruption.frameworkURLs.count)))
        await imageLoading.waitUntilReady(engine)
        presentsInEditorArea = documentState.editorArea.hasShownNothing
        await loadSequence(interruption.frameworkURLs, on: engine)
    }

    // MARK: - Steps

    private enum LoadOutcome {
        case loaded
        case refused(any Error)
        case instanceStopped
    }

    private func loadSequence(_ frameworkURLs: [URL], on engine: RuntimeEngine) async {
        var loadedImagePaths: [String] = []
        for (index, frameworkURL) in frameworkURLs.enumerated() {
            setState(.loading(.init(frameworkURL: frameworkURL, position: index + 1, count: frameworkURLs.count)))
            let remainingFrameworkURLs = Array(frameworkURLs[(index + 1)...])
            let imagePath: String
            do {
                imagePath = try Self.executablePath(ofFrameworkAt: frameworkURL, resolvingLinks: Self.isFrameworkInstance(engine))
            } catch {
                setState(.failed(.init(
                    frameworkURL: frameworkURL,
                    diagnosis: RuntimeImageLoadDiagnosis(dyldMessage: error.localizedDescription, imagePath: frameworkURL.path),
                    remainingFrameworkURLs: remainingFrameworkURLs,
                    offersRemedies: false
                )))
                return
            }
            switch await loadImage(at: imagePath, on: engine) {
            case .loaded:
                loadedImagePaths.append(imagePath)
            case .refused(let error):
                setState(.failed(await diagnosedFailure(for: frameworkURL, imagePath: imagePath, error: error, remainingFrameworkURLs: remainingFrameworkURLs, on: engine)))
                return
            case .instanceStopped:
                setState(.instanceStopped(.init(frameworkURLs: requestedFrameworkURLs, interruptedFrameworkURL: frameworkURL)))
                return
            }
        }
        setState(.idle)
        openImageIfNothingIsShown(loadedImagePaths.first, on: engine)
    }

    private func loadImage(at imagePath: String, on engine: RuntimeEngine) async -> LoadOutcome {
        let imageLoading = imageLoading
        do {
            try await documentState.recordingManualLoad(ofImageAt: imagePath) { _ in
                try await imageLoading.loadImage(engine, imagePath)
            }
            return .loaded
        } catch let error as RuntimeImageLoadError {
            return .refused(error)
        } catch {
            // A framework instance is of this build and reports every refusal
            // as a `RuntimeImageLoadError`: anything else is its connection
            // failing — the instance went away.
            if Self.isFrameworkInstance(engine) {
                #log(.error, "The framework instance stopped while loading \(imagePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return .instanceStopped
            }
            return .refused(error)
        }
    }

    /// The refusal of `imagePath`, diagnosed: by the serving process, or from
    /// dyld's message when the process is of an earlier version — and, on a
    /// framework instance, retraced once more with the host app and folders
    /// the window keeps when that finds what the first diagnosis did not.
    private func diagnosedFailure(
        for frameworkURL: URL,
        imagePath: String,
        error: any Error,
        remainingFrameworkURLs: [URL],
        on engine: RuntimeEngine
    ) async -> FrameworkLoadFailure {
        let loadError = error as? RuntimeImageLoadError
        var diagnosis = loadError?.diagnosis
            ?? RuntimeImageLoadDiagnosis(dyldMessage: loadError?.dyldMessage ?? error.localizedDescription, imagePath: imagePath)
        let offersRemedies = Self.isFrameworkInstance(engine)
        if offersRemedies, diagnosis.remedy == nil, hostApplicationURL != nil || !searchDirectoryURLs.isEmpty {
            if let retraced = try? await imageLoading.diagnoseImageLoad(engine, diagnosis, hostApplicationURL?.path, searchDirectoryURLs.map(\.path)) {
                diagnosis = retraced
            }
        }
        return FrameworkLoadFailure(
            frameworkURL: frameworkURL,
            diagnosis: diagnosis,
            remainingFrameworkURLs: remainingFrameworkURLs,
            offersRemedies: offersRemedies
        )
    }

    private func diagnoseAgainAndApplyRemedy() async {
        guard case .failed(var failure) = state, failure.offersRemedies else { return }
        let engine = documentState.runtimeEngine
        do {
            failure.diagnosis = try await imageLoading.diagnoseImageLoad(
                engine,
                failure.diagnosis,
                hostApplicationURL?.path,
                searchDirectoryURLs.map(\.path)
            )
        } catch {
            #log(.error, "Could not retrace the refused load of \(failure.diagnosis.imagePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return
        }
        setState(.failed(failure))
        if failure.diagnosis.remedy != nil {
            await applyRemedy()
        }
    }

    /// A window that showed nothing when it asked opens the first framework's
    /// image page, which indexes it.
    private func openImageIfNothingIsShown(_ imagePath: String?, on engine: RuntimeEngine) {
        guard Self.isFrameworkInstance(engine), presentsInEditorArea,
              let imagePath, documentState.runtimeEngine === engine, documentState.editorArea.hasShownNothing
        else { return }
        documentState.selectionRouter.trigger(.openImage(imagePath, in: .focusedTab))
    }

    private func setState(_ newState: FrameworkLoadState) {
        let isFrameworkInstance = Self.isFrameworkInstance(documentState.runtimeEngine)
        switch newState {
        case .idle:
            showsPageInEmptyPanes = false
        case .instanceStopped:
            showsPageInEmptyPanes = isFrameworkInstance
        case .loading, .failed:
            showsPageInEmptyPanes = isFrameworkInstance && presentsInEditorArea
        }
        state = newState
    }

    // MARK: - The Instance

    /// Hears a framework instance go away while nothing is loading: a
    /// framework's thread crashed it after the load. The connection comes back
    /// to a new, empty instance on its own; the window says the frameworks are
    /// gone. A load in flight hears it from its own request.
    private func followInstance(_ engine: RuntimeEngine) {
        guard Self.isFrameworkInstance(engine), followedEngine != ObjectIdentifier(engine) else { return }
        followedEngine = ObjectIdentifier(engine)
        followedEngineWasReady = engine.state.isReady
        engineStateSubscription = engine.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] engineState in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let wasReady = self.followedEngineWasReady
                    self.followedEngineWasReady = engineState.isReady
                    guard wasReady, !engineState.isReady, self.documentState.runtimeEngine === engine else { return }
                    switch self.state {
                    case .idle, .failed:
                        guard !self.requestedFrameworkURLs.isEmpty else { return }
                        self.setState(.instanceStopped(.init(frameworkURLs: self.requestedFrameworkURLs, interruptedFrameworkURL: nil)))
                    case .loading, .instanceStopped:
                        break
                    }
                }
            }
    }

    // MARK: - Support

    static func isFrameworkInstance(_ engine: RuntimeEngine) -> Bool {
        if case .frameworkInstance = engine.source { return true }
        return false
    }

    /// The executable of the framework at `frameworkURL` — or the file itself,
    /// for an image a remedy names — spelled as dyld lists it when
    /// `resolvingLinks`: a framework instance runs on this Mac, and its lists
    /// name images by their real paths.
    static func executablePath(ofFrameworkAt frameworkURL: URL, resolvingLinks: Bool) throws -> String {
        let path: String
        var isDirectory: ObjCBool = false
        if let executableURL = Bundle(url: frameworkURL)?.executableURL {
            path = executableURL.path
        } else if FileManager.default.fileExists(atPath: frameworkURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            path = frameworkURL.path
        } else {
            throw LoadError.noExecutable(frameworkURL)
        }
        guard resolvingLinks, let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
