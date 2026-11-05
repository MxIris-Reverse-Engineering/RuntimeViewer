import Foundation

public enum RuntimeObjectsLoadingEvent: Sendable {
    case progress(RuntimeObjectsLoadingProgress)
    case completed([RuntimeObject])
}

typealias LoadingEventContinuation = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Swift.Error>.Continuation
