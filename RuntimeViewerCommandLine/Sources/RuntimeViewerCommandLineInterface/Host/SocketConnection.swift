import Darwin
import Foundation

/// One framed, bidirectional channel over a connected socket descriptor.
///
/// Reads run on a `DispatchIO` channel and surface as whole payloads on
/// ``incomingPayloads``; writes go through the same channel and complete when
/// the last byte has been handed to the kernel. Nothing here blocks a
/// cooperative thread.
final class SocketConnection: @unchecked Sendable {
    let incomingPayloads: AsyncThrowingStream<Data, any Error>

    private let continuation: AsyncThrowingStream<Data, any Error>.Continuation
    private let channel: DispatchIO
    private let queue = DispatchQueue(label: "dev.JH.RuntimeViewerCommandLine.SocketConnection")
    private var decoder = FrameCodec.Decoder()
    private var isClosed = false

    init(fileDescriptor: Int32) {
        (incomingPayloads, continuation) = AsyncThrowingStream<Data, any Error>.makeStream()
        channel = DispatchIO(type: .stream, fileDescriptor: fileDescriptor, queue: queue) { _ in
            Darwin.close(fileDescriptor)
        }
        channel.setLimit(lowWater: 1)
        startReading()
    }

    private func startReading() {
        channel.read(offset: 0, length: Int.max, queue: queue) { [weak self] done, data, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                var bytes = Data(capacity: data.count)
                data.enumerateBytes { buffer, _, _ in
                    bytes.append(contentsOf: buffer)
                }
                decoder.append(bytes)
                do {
                    while let payload = try decoder.nextPayload() {
                        continuation.yield(payload)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    channel.close(flags: .stop)
                    return
                }
            }
            if error != 0 {
                if error == ECANCELED {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: UnixDomainSocket.SystemError("read", code: error))
                }
                return
            }
            if done {
                continuation.finish()
            }
        }
    }

    func send(_ frame: Data) async throws {
        let dispatchData = frame.withUnsafeBytes { DispatchData(bytes: $0) }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            channel.write(offset: 0, data: dispatchData, queue: queue) { done, _, error in
                guard done else { return }
                if error != 0 {
                    continuation.resume(throwing: UnixDomainSocket.SystemError("write", code: error))
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func close() {
        queue.async { [self] in
            guard !isClosed else { return }
            isClosed = true
            channel.close(flags: .stop)
            continuation.finish()
        }
    }
}
