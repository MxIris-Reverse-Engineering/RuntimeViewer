import Foundation

public final class RuntimeInterfaceExportReporter: Sendable {
    public let events: AsyncStream<RuntimeInterfaceExportEvent>
    
    private let continuation: AsyncStream<RuntimeInterfaceExportEvent>.Continuation

    public init() {
        (events, continuation) = AsyncStream<RuntimeInterfaceExportEvent>.makeStream()
    }

    func send(_ event: RuntimeInterfaceExportEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}
