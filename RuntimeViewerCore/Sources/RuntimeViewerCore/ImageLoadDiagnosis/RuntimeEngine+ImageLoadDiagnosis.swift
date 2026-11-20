import Foundation
import RuntimeViewerCommunication

extension RuntimeEngine {
    /// Whether `diagnoseImageLoad(at:dyldMessage:hostApplicationPath:searchPaths:)`
    /// may be asked: the process that serves this engine is of this build —
    /// this one, or the local service the app embeds. Engines do not exchange
    /// versions, and an injected payload of an earlier release drops its
    /// connection on a command it does not know (PR121.73), so no other engine
    /// is ever sent the command. A refused load reports its diagnosis in the
    /// load's own reply instead, which every engine of this build fills.
    public nonisolated var diagnosesImageLoadsOnRequest: Bool {
        switch source {
        case .local, .frameworkInstance:
            return true
        case .remote, .bonjour, .localSocket, .directTCP, .injectedTCP, .file:
            return false
        }
    }

    /// Retraces dyld's search for the image at `imagePath`, which the process
    /// serving this engine refused with `dyldMessage`, as if the app at
    /// `hostApplicationPath` were the main executable and `searchPaths` were
    /// searched after the rpath stack — to find what to load first.
    ///
    /// Throws `RuntimeNetworkRequestError.unknownCommand(named:)` without
    /// asking when `diagnosesImageLoadsOnRequest` is false.
    public func diagnoseImageLoad(
        at imagePath: String,
        dyldMessage: String,
        hostApplicationPath: String? = nil,
        searchPaths: [String] = []
    ) async throws -> RuntimeImageLoadDiagnosis {
        guard diagnosesImageLoadsOnRequest else {
            throw RuntimeNetworkRequestError.unknownCommand(named: DiagnoseImageLoadCommand.commandName)
        }
        return try await dispatchToServingProcess(DiagnoseImageLoadCommand(
            imagePath: imagePath,
            dyldMessage: dyldMessage,
            hostApplicationPath: hostApplicationPath,
            searchPaths: searchPaths
        ))
    }

    /// The failure a refused `dlopen` of `imagePath` reports to a requester
    /// that asked for a diagnosis, worked out in this process.
    nonisolated func diagnosedLoadFailure(_ error: DyldOpenError, forImageAt imagePath: String) -> RuntimeImageLoadError {
        let dyldMessage = error.errorDescription ?? ""
        let diagnosis = RuntimeImageLoadDiagnostician(environment: .currentProcess())
            .diagnose(imageAt: imagePath, dyldMessage: dyldMessage)
        return RuntimeImageLoadError(dyldMessage: dyldMessage, diagnosis: diagnosis)
    }
}
