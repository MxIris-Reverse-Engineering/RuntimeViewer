import Foundation
import Logging
import Semaphore
import Asynchrone

#if canImport(Darwin)
import Darwin
#endif

// MARK: - RuntimeLocalSocketConnection

/// A bidirectional communication channel over TCP localhost socket.
///
/// `RuntimeLocalSocketConnection` provides a universal IPC mechanism that works
/// across all scenarios including sandboxed apps and code injection, without
/// requiring any special entitlements or Info.plist configuration.
///
/// ## Why TCP Localhost?
///
/// | Method | Sandbox Compatible | No Config Required |
/// |--------|-------------------|-------------------|
/// | XPC Mach Service | ❌ | ✅ |
/// | Bonjour/Network | ❌ (needs NSBonjourServices) | ❌ |
/// | Unix Domain Socket | ❌ (path restrictions) | ✅ |
/// | **TCP Localhost** | **✅** | **✅** |
///
/// ## Architecture for Code Injection
///
/// ```
/// ┌─────────────────────┐                    ┌─────────────────────┐
/// │  RuntimeViewer      │                    │  Target Process     │
/// │  (Main App)         │                    │                     │
/// │                     │   1. inject dylib  │                     │
/// │                     │ ──────────────────>│  [Injected Code]    │
/// │                     │                    │                     │
/// │                     │   2. write port    │                     │
/// │                     │      to file       │                     │
/// │  LocalSocketServer ◄┼─── 127.0.0.1:port ─┼──► LocalSocketClient│
/// │  (port discovery)   │                    │  (reads port file)  │
/// └─────────────────────┘                    └─────────────────────┘
/// ```
///
/// ## Port Discovery Mechanism
///
/// Since we can't hardcode ports, we use a file-based discovery:
/// 1. Server binds to port 0 (system assigns available port)
/// 2. Server writes port number to a known file path
/// 3. Client reads the port file and connects
///
/// ## Example: Main App (Server)
///
/// ```swift
/// // Start server with auto port discovery
/// let server = try RuntimeLocalSocketServerConnection(
///     identifier: "com.myapp.runtime-\(targetPID)"
/// )
/// try await server.start()
///
/// // Server is now listening, port file is written
/// // Inject dylib into target process...
///
/// // Handle requests from injected code
/// server.setMessageHandler(requestType: RuntimeInfoRequest.self) { request in
///     return RuntimeInfoResponse(...)
/// }
/// ```
///
/// ## Example: Injected Code (Client)
///
/// ```swift
/// @_cdecl("injected_entry")
/// func injectedEntry() {
///     Task {
///         // Connect using the same identifier
///         let client = try RuntimeLocalSocketClientConnection(
///             identifier: "com.myapp.runtime-\(getpid())"
///         )
///
///         // Now can communicate with main app
///         client.setMessageHandler(requestType: QueryRequest.self) { request in
///             // Return runtime information
///             return QueryResponse(classes: objc_copyClassList()...)
///         }
///     }
/// }
/// ```
///
final class RuntimeLocalSocketConnection: @unchecked Sendable {
    private class MessageHandler {
        typealias RawHandler = (Data) async throws -> Data
        let closure: RawHandler
        let requestType: Codable.Type
        let responseType: Codable.Type

        init<Request: Codable, Response: Codable>(closure: @escaping (Request) async throws -> Response) {
            self.requestType = Request.self
            self.responseType = Response.self

            self.closure = { request in
                let request = try JSONDecoder().decode(Request.self, from: request)
                let response = try await closure(request)
                return try JSONEncoder().encode(response)
            }
        }
    }

    let id = UUID()

    var didStop: ((RuntimeLocalSocketConnection) -> Void)?

    var didReady: ((RuntimeLocalSocketConnection) -> Void)?

    private static let logger = Logger(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeLocalSocketConnection")

    private static let endMarkerData = "\nOK".data(using: .utf8)!

    private var logger: Logger { Self.logger }

    private var socketFD: Int32 = -1

    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    private var receivedDataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    private var isStarted = false

    private var receivingData = Data()

    private let semaphore = AsyncSemaphore(value: 1)

    private var messageHandlers: [String: MessageHandler] = [:]

    private let readQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeLocalSocketConnection.readQueue")

    private let writeQueue = DispatchQueue(label: "com.RuntimeViewer.RuntimeViewerCommunication.RuntimeLocalSocketConnection.writeQueue")

    init(socketFD: Int32) {
        self.socketFD = socketFD
    }

    init(port: UInt16) throws {
        Self.logger.info("RuntimeLocalSocketConnection connecting to localhost:\(port)")
        try connectToLocalhost(port: port)
    }

    private func connectToLocalhost(port: UInt16) throws {
        socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw RuntimeLocalSocketError.socketCreationFailed
        }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard result == 0 else {
            let error = errno
            close(socketFD)
            socketFD = -1
            throw RuntimeLocalSocketError.connectFailed(error)
        }

        Self.logger.info("Connected to localhost:\(port)")
    }

    func start() throws {
        guard !isStarted else { return }
        guard socketFD >= 0 else { throw RuntimeLocalSocketError.notConnected }
        isStarted = true
        Self.logger.info("Local socket connection will start")
        setupStreams()
        setupReceiver()
        observeIncomingMessages()
        didReady?(self)
        didReady = nil
        Self.logger.info("Local socket connection did start")
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        Self.logger.info("Local socket connection will stop")
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        receivedDataContinuation?.finish()
        didStop?(self)
        didStop = nil
        Self.logger.info("Local socket connection did stop")
    }

    func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping ((Request) async throws -> Response)) {
        messageHandlers[name] = .init(closure: handler)
    }

    func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping ((Request) async throws -> Request.Response)) {
        messageHandlers[Request.identifier] = .init(closure: handler)
    }

    func send(requestData: RuntimeRequestData) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeLocalSocketConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
    }

    func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeLocalSocketConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
        let receiveData = try await receiveData()
        let responseData = try JSONDecoder().decode(RuntimeRequestData.self, from: receiveData)
        logger.info("RuntimeLocalSocketConnection received identifier: \(responseData.identifier)")
        return try JSONDecoder().decode(Response.self, from: responseData.data)
    }

    func send<Request: RuntimeRequest>(request: Request) async throws {
        let requestData = try RuntimeRequestData(request: request)
        try await send(requestData: requestData)
    }

    func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
        let requestData = try RuntimeRequestData(request: request)
        return try await send(requestData: requestData)
    }

    private func observeIncomingMessages() {
        Task {
            do {
                guard let receivedDataStream else { return }
                for try await data in receivedDataStream {
                    do {
                        let requestData = try JSONDecoder().decode(RuntimeRequestData.self, from: data)
                        guard let messageHandler = messageHandlers[requestData.identifier] else { continue }
                        logger.info("RuntimeLocalSocketConnection received identifier: \(requestData.identifier)")
                        let responseData = try await messageHandler.closure(requestData.data)
                        if messageHandler.responseType != MessageNull.self {
                            try await send(requestData: RuntimeRequestData(identifier: requestData.identifier, data: responseData))
                        }
                    } catch {
                        logger.error("\(error)")
                        let requestError = RuntimeNetworkRequestError(message: "\(error)")
                        do {
                            let commandErrorData = try JSONEncoder().encode(requestError)
                            try await send(data: commandErrorData)
                        } catch {
                            logger.error("\(error)")
                        }
                    }
                }

            } catch {
                logger.error("\(error)")
            }
        }
    }

    private func setupStreams() {
        let (receivedDataStream, receivedDataContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.receivedDataStream = receivedDataStream.shared()
        self.receivedDataContinuation = receivedDataContinuation
    }

    private func setupReceiver() {
        readQueue.async { [weak self] in
            guard let self else { return }
            var buffer = [UInt8](repeating: 0, count: 65536)

            while self.isStarted && self.socketFD >= 0 {
                let bytesRead = recv(self.socketFD, &buffer, buffer.count, 0)
                if bytesRead > 0 {
                    let data = Data(buffer[0..<bytesRead])
                    self.receivingData.append(data)
                    self.processReceivedData()
                } else if bytesRead == 0 {
                    self.receivedDataContinuation?.finish()
                    DispatchQueue.main.async {
                        self.stop()
                    }
                    break
                } else {
                    let error = errno
                    if error != EAGAIN && error != EWOULDBLOCK {
                        self.receivedDataContinuation?.finish()
                        DispatchQueue.main.async {
                            self.stop()
                        }
                        break
                    }
                }
            }
        }
    }

    private func processReceivedData() {
        guard let endMarker = "\nOK".data(using: .utf8) else { return }

        while true {
            guard let endRange = receivingData.range(of: endMarker) else {
                break
            }

            let messageData = receivingData.subdata(in: 0 ..< endRange.lowerBound)
            receivedDataContinuation?.yield(messageData)

            if endRange.upperBound < receivingData.count {
                receivingData = receivingData.subdata(in: endRange.upperBound ..< receivingData.count)
            } else {
                receivingData = Data()
                break
            }
        }
    }

    private func send<Content: Codable>(content: Content) async throws {
        let data = try JSONEncoder().encode(content)
        try await send(data: data)
    }

    private func send(data: Data) async throws {
        guard socketFD >= 0 else { throw RuntimeLocalSocketError.notConnected }

        let dataToSend = data + Self.endMarkerData

        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) in
            guard let self else {
                continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                return
            }

            self.writeQueue.async { [weak self] in
                guard let self, self.socketFD >= 0 else {
                    continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                    return
                }

                dataToSend.withUnsafeBytes { buffer in
                    guard let baseAddress = buffer.baseAddress else {
                        continuation.resume(throwing: RuntimeLocalSocketError.notConnected)
                        return
                    }

                    var totalSent = 0
                    while totalSent < dataToSend.count {
                        let sent = Darwin.send(self.socketFD, baseAddress.advanced(by: totalSent), dataToSend.count - totalSent, 0)
                        if sent < 0 {
                            continuation.resume(throwing: RuntimeLocalSocketError.sendFailed(errno))
                            return
                        }
                        totalSent += sent
                    }
                    Self.logger.info("RuntimeLocalSocketConnection send data: \(data)")
                    continuation.resume()
                }
            }
        }
    }

    private func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            throw RuntimeLocalSocketError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                throw error
            } else {
                return data
            }
        }

        throw RuntimeLocalSocketError.receiveFailed
    }
}

// MARK: - RuntimeLocalSocketError

/// Errors that can occur during local socket communication.
enum RuntimeLocalSocketError: Error {
    case notConnected
    case receiveFailed
    case socketCreationFailed
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
    case connectFailed(Int32)
    case sendFailed(Int32)
    case portFileNotFound
    case invalidPortFile
}

// MARK: - RuntimeLocalSocketPortDiscovery

/// Handles port discovery via file system for sandboxed environments.
///
/// The port file is stored in a location accessible to both processes:
/// - `/tmp/RuntimeViewer/{identifier}.port` for non-sandboxed apps
/// - User's temp directory for sandboxed apps
enum RuntimeLocalSocketPortDiscovery {

    /// Returns the port file path for the given identifier.
    static func portFilePath(for identifier: String) -> URL {
        let sanitizedIdentifier = identifier.replacingOccurrences(of: "/", with: "_")

        // Use /tmp for maximum compatibility
        // Both sandboxed and non-sandboxed apps can typically access /tmp
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeViewer", isDirectory: true)

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        return directory.appendingPathComponent("\(sanitizedIdentifier).port")
    }

    /// Writes the port number to the discovery file.
    static func writePort(_ port: UInt16, identifier: String) throws {
        let path = portFilePath(for: identifier)
        let data = "\(port)".data(using: .utf8)!
        try data.write(to: path, options: .atomic)
        Logger(label: "RuntimeLocalSocketPortDiscovery").info("Port \(port) written to \(path.path)")
    }

    /// Reads the port number from the discovery file.
    static func readPort(identifier: String, timeout: TimeInterval = 10) async throws -> UInt16 {
        let path = portFilePath(for: identifier)
        let logger = Logger(label: "RuntimeLocalSocketPortDiscovery")
        let startTime = Date()

        // Poll for port file with timeout
        while Date().timeIntervalSince(startTime) < timeout {
            if FileManager.default.fileExists(atPath: path.path) {
                let data = try Data(contentsOf: path)
                guard let portString = String(data: data, encoding: .utf8),
                      let port = UInt16(portString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw RuntimeLocalSocketError.invalidPortFile
                }
                logger.info("Port \(port) read from \(path.path)")
                return port
            }

            // Wait before retry
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        throw RuntimeLocalSocketError.portFileNotFound
    }

    /// Removes the port file.
    static func removePortFile(identifier: String) {
        let path = portFilePath(for: identifier)
        try? FileManager.default.removeItem(at: path)
    }
}

// MARK: - MessageNull

private struct MessageNull: Codable {
    static let null = MessageNull()
}

// MARK: - RuntimeLocalSocketBaseConnection

/// Base class implementing `RuntimeConnection` protocol for local socket communication.
class RuntimeLocalSocketBaseConnection: RuntimeConnection {
    var connection: RuntimeLocalSocketConnection?

    init() {}

    func sendMessage(name: String) async throws {
        guard let connection = connection else { throw RuntimeLocalSocketError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage(name: String, request: some Codable) async throws {
        guard let connection = connection else { throw RuntimeLocalSocketError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func sendMessage<Response>(name: String) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeLocalSocketError.notConnected }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage<Request>(request: Request) async throws -> Request.Response where Request: RuntimeRequest {
        guard let connection = connection else { throw RuntimeLocalSocketError.notConnected }
        return try await connection.send(request: request)
    }

    func sendMessage<Response>(name: String, request: some Codable) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeLocalSocketError.notConnected }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func setMessageHandler(name: String, handler: @escaping () async throws -> Void) {
        connection?.setMessageHandler(name: name, handler: { (_: MessageNull) in
            try await handler()
            return MessageNull.null
        })
    }

    func setMessageHandler<Request>(name: String, handler: @escaping (Request) async throws -> Void) where Request: Decodable, Request: Encodable {
        connection?.setMessageHandler(name: name, handler: { (request: Request) in
            try await handler(request)
            return MessageNull.null
        })
    }

    func setMessageHandler<Response>(name: String, handler: @escaping () async throws -> Response) where Response: Decodable, Response: Encodable {
        connection?.setMessageHandler(name: name, handler: { (_: MessageNull) in
            return try await handler()
        })
    }

    func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        connection?.setMessageHandler { (request: Request) in
            return try await handler(request)
        }
    }

    func setMessageHandler<Request, Response>(name: String, handler: @escaping (Request) async throws -> Response) where Request: Decodable, Request: Encodable, Response: Decodable, Response: Encodable {
        connection?.setMessageHandler(name: name, handler: { (request: Request) in
            return try await handler(request)
        })
    }
}

// MARK: - RuntimeLocalSocketClientConnection

/// Client-side local socket connection that discovers server port automatically.
///
/// ## Usage in Injected Code
///
/// ```swift
/// @_cdecl("injected_entry")
/// func injectedEntry() {
///     Task {
///         // The identifier must match what the server used
///         let client = try await RuntimeLocalSocketClientConnection(
///             identifier: "com.myapp.runtime-\(getpid())"
///         )
///
///         // Register handlers for requests from main app
///         client.setMessageHandler(requestType: GetClassesRequest.self) { request in
///             return GetClassesResponse(classes: ...)
///         }
///
///         // Or send requests to main app
///         let config = try await client.sendMessage(request: GetConfigRequest())
///     }
/// }
/// ```
final class RuntimeLocalSocketClientConnection: RuntimeLocalSocketBaseConnection {
    private let identifier: String

    /// Creates a client connection that auto-discovers the server port.
    ///
    /// - Parameters:
    ///   - identifier: Unique identifier matching the server's identifier.
    ///   - timeout: Maximum time to wait for port discovery (default: 10 seconds).
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(identifier: String, timeout: TimeInterval = 10) async throws {
        self.identifier = identifier
        super.init()

        // Discover port from file
        let port = try await RuntimeLocalSocketPortDiscovery.readPort(identifier: identifier, timeout: timeout)

        // Connect to server
        let connection = try RuntimeLocalSocketConnection(port: port)
        self.connection = connection
        try connection.start()
    }

    /// Creates a client connection to a known port.
    ///
    /// - Parameters:
    ///   - port: The server port to connect to.
    /// - Throws: `RuntimeLocalSocketError` if connection cannot be established.
    init(port: UInt16) throws {
        self.identifier = ""
        super.init()

        let connection = try RuntimeLocalSocketConnection(port: port)
        self.connection = connection
        try connection.start()
    }
}

// MARK: - RuntimeLocalSocketServerConnection

/// Server-side local socket connection that listens on localhost.
///
/// ## Usage in Main App
///
/// ```swift
/// // Before injecting code, start the server
/// let server = try RuntimeLocalSocketServerConnection(
///     identifier: "com.myapp.runtime-\(targetPID)"
/// )
/// try await server.start()
///
/// print("Server listening on port: \(server.port)")
///
/// // Now inject the dylib into target process...
/// // The injected code will discover the port automatically
///
/// // Handle requests from injected code
/// server.setMessageHandler(requestType: LogRequest.self) { request in
///     print("Log from injected: \(request.message)")
///     return VoidResponse()
/// }
/// ```
final class RuntimeLocalSocketServerConnection: RuntimeLocalSocketBaseConnection, @unchecked Sendable {
    private var serverSocketFD: Int32 = -1
    private let identifier: String

    /// Pending message handlers to apply to new connections.
    private var pendingHandlers: [(RuntimeLocalSocketConnection) -> Void] = []

    /// The port the server is listening on (available after `start()` is called).
    private(set) var port: UInt16 = 0

    /// Creates a server connection with automatic port assignment.
    ///
    /// - Parameter identifier: Unique identifier for port discovery.
    init(identifier: String) {
        self.identifier = identifier
        super.init()
    }

    /// Creates a server connection on a specific port.
    ///
    /// - Parameter port: The port to listen on (0 for auto-assign).
    init(port: UInt16 = 0) {
        self.identifier = ""
        self.port = port
        super.init()
    }

    // MARK: - Message Handler Overrides

    override func setMessageHandler(name: String, handler: @escaping () async throws -> Void) {
        let setupHandler: (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { (_: MessageNull) in
                try await handler()
                return MessageNull.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = connection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(name: String, handler: @escaping (Request) async throws -> Void) where Request: Codable {
        let setupHandler: (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { (request: Request) in
                try await handler(request)
                return MessageNull.null
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = connection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Response>(name: String, handler: @escaping () async throws -> Response) where Response: Codable {
        let setupHandler: (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { (_: MessageNull) in
                return try await handler()
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = connection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request>(requestType: Request.Type, handler: @escaping (Request) async throws -> Request.Response) where Request: RuntimeRequest {
        let setupHandler: (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler { (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = connection {
            setupHandler(connection)
        }
    }

    override func setMessageHandler<Request, Response>(name: String, handler: @escaping (Request) async throws -> Response) where Request: Codable, Response: Codable {
        let setupHandler: (RuntimeLocalSocketConnection) -> Void = { connection in
            connection.setMessageHandler(name: name) { (request: Request) in
                return try await handler(request)
            }
        }
        pendingHandlers.append(setupHandler)
        if let connection = connection {
            setupHandler(connection)
        }
    }

    /// Applies all pending handlers to a connection.
    private func applyPendingHandlers(to connection: RuntimeLocalSocketConnection) {
        for handler in pendingHandlers {
            handler(connection)
        }
    }

    /// Starts listening for connections.
    ///
    /// After this method returns, the server is ready to accept connections
    /// and the port file has been written for client discovery.
    /// Connections are accepted asynchronously in the background.
    func start() async throws {
        serverSocketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverSocketFD >= 0 else {
            throw RuntimeLocalSocketError.socketCreationFailed
        }

        var reuseAddr: Int32 = 1
        setsockopt(serverSocketFD, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        guard bindResult == 0 else {
            let error = errno
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.bindFailed(error)
        }

        // Get the actual port if we bound to port 0
        if port == 0 {
            var boundAddr = sockaddr_in()
            var boundAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafeMutablePointer(to: &boundAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    getsockname(serverSocketFD, sockaddrPtr, &boundAddrLen)
                }
            }
            port = UInt16(bigEndian: boundAddr.sin_port)
        }

        guard listen(serverSocketFD, 5) == 0 else {
            let error = errno
            close(serverSocketFD)
            serverSocketFD = -1
            throw RuntimeLocalSocketError.listenFailed(error)
        }

        // Write port file for discovery
        if !identifier.isEmpty {
            try RuntimeLocalSocketPortDiscovery.writePort(port, identifier: identifier)
        }

        Logger(label: "RuntimeLocalSocketServerConnection").info("Server listening on 127.0.0.1:\(port)")

        // Start accepting connections in background (non-blocking)
        startAcceptingConnections()
    }

    /// Starts accepting connections asynchronously in background.
    private func startAcceptingConnections() {
        DispatchQueue.global().async { [weak self] in
            self?.acceptConnectionLoop()
        }
    }

    /// Continuously accepts client connections.
    private func acceptConnectionLoop() {
        guard serverSocketFD >= 0 else { return }

        var clientAddr = sockaddr_in()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(serverSocketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            // Accept failed, likely server was stopped
            return
        }

        let socketConnection = RuntimeLocalSocketConnection(socketFD: clientFD)
        self.connection = socketConnection

        // Apply all pending message handlers to the new connection
        applyPendingHandlers(to: socketConnection)

        socketConnection.didStop = { [weak self] _ in
            // When connection stops, start accepting new connections
            self?.startAcceptingConnections()
        }

        do {
            try socketConnection.start()
        } catch {
            Logger(label: "RuntimeLocalSocketServerConnection").error("Failed to start connection: \(error)")
            // Try accepting again
            startAcceptingConnections()
        }
    }

    /// Stops the server and cleans up resources.
    func stop() {
        connection?.stop()
        if serverSocketFD >= 0 {
            close(serverSocketFD)
            serverSocketFD = -1
        }

        // Clean up port file
        if !identifier.isEmpty {
            RuntimeLocalSocketPortDiscovery.removePortFile(identifier: identifier)
        }
    }

    deinit {
        stop()
    }
}
