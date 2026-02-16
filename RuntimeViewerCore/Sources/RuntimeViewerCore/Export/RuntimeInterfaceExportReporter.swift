import Foundation

public final class RuntimeInterfaceExportReporter: Sendable {
    public let events: AsyncStream<RuntimeInterfaceExportEvent>
    private let continuation: AsyncStream<RuntimeInterfaceExportEvent>.Continuation

    public init() {
        var cont: AsyncStream<RuntimeInterfaceExportEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(_ event: RuntimeInterfaceExportEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}
