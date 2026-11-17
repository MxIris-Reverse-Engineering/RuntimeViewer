import Foundation

/// The system's own socket calls, which every local socket connection makes
/// outside tests.
struct RuntimeDarwinSocketSystemCalls: RuntimeSocketSystemCalls {
    func accept(_ socketDescriptor: Int32) -> Int32 {
        Darwin.accept(socketDescriptor, nil, nil)
    }

    func receive(_ socketDescriptor: Int32, into buffer: UnsafeMutableRawBufferPointer) -> Int {
        Darwin.recv(socketDescriptor, buffer.baseAddress, buffer.count, 0)
    }

    func send(_ socketDescriptor: Int32, from buffer: UnsafeRawBufferPointer) -> Int {
        Darwin.send(socketDescriptor, buffer.baseAddress, buffer.count, 0)
    }

    func shutdown(_ socketDescriptor: Int32) {
        _ = Darwin.shutdown(socketDescriptor, SHUT_RDWR)
    }

    func close(_ socketDescriptor: Int32) {
        _ = Darwin.close(socketDescriptor)
    }
}
