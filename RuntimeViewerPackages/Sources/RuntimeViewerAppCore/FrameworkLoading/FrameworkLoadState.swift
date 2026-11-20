import Foundation
import RuntimeViewerCore

/// Where a window's Load Frameworks stands (`FrameworkLoader`).
public enum FrameworkLoadState: Equatable, Sendable {
    /// Nothing loading, nothing failed.
    case idle
    /// A framework of the request is loading.
    case loading(FrameworkLoadProgress)
    /// dyld refused a framework, or a dependency loaded first for it; the
    /// frameworks after it wait.
    case failed(FrameworkLoadFailure)
    /// The instance the window's frameworks were loaded into went away — it
    /// crashed, most likely in a framework's constructor — and its connection
    /// came back to a new instance with nothing loaded. Nothing is loaded again
    /// until the user asks.
    case instanceStopped(FrameworkLoadInterruption)

    public var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

/// The framework loading, and where it is in the request.
public struct FrameworkLoadProgress: Equatable, Sendable {
    public var frameworkURL: URL
    /// One-based.
    public var position: Int
    public var count: Int

    public init(frameworkURL: URL, position: Int, count: Int) {
        self.frameworkURL = frameworkURL
        self.position = position
        self.count = count
    }
}

/// A framework dyld refused, with why.
public struct FrameworkLoadFailure: Equatable, Sendable {
    /// The framework the user picked, or the image a remedy loaded first.
    public var frameworkURL: URL
    public var diagnosis: RuntimeImageLoadDiagnosis
    /// The frameworks of the request after this one, loaded once it loads.
    public var remainingFrameworkURLs: [URL]
    /// Retry, the remedy, Choose Host App and Add Search Path: only for frameworks
    /// loaded into an instance of their own. Another engine's process is not
    /// the app's, and loading more into it is not what the user asked for.
    public var offersRemedies: Bool

    public init(frameworkURL: URL, diagnosis: RuntimeImageLoadDiagnosis, remainingFrameworkURLs: [URL], offersRemedies: Bool) {
        self.frameworkURL = frameworkURL
        self.diagnosis = diagnosis
        self.remainingFrameworkURLs = remainingFrameworkURLs
        self.offersRemedies = offersRemedies
    }
}

/// What the window had asked for when its instance went away.
public struct FrameworkLoadInterruption: Equatable, Sendable {
    /// Every framework the window asked for, to load again in the new instance.
    public var frameworkURLs: [URL]
    /// The framework loading when the instance went away, if one was.
    public var interruptedFrameworkURL: URL?

    public init(frameworkURLs: [URL], interruptedFrameworkURL: URL?) {
        self.frameworkURLs = frameworkURLs
        self.interruptedFrameworkURL = interruptedFrameworkURL
    }
}
