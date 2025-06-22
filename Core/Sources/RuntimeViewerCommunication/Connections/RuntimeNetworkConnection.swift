import Foundation
import Network
import Asynchrone
import Semaphore
import Logging

class RuntimeNetworkConnection {
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

    private typealias ReceiveType = (Data?, NWConnection.ContentContext?, Bool, NWError?) -> Void

    public let id = UUID()

    public var didStop: ((RuntimeNetworkConnection) -> Void)?

    public var didReady: ((RuntimeNetworkConnection) -> Void)?

    private let connection: NWConnection

    private static let logger = Logger(label: "RuntimeNetworkConnection")

    private static let endMarkerData = "\nOK".data(using: .utf8)!

    private var logger: Logger { Self.logger }

    private let queue = DispatchQueue(label: "com.JH.LocalizationStudioCommunication.Connection.queue")

    private var connectionStateStream: AsyncStream<NWConnection.State>?

    private var connectionStateContinuation: AsyncStream<NWConnection.State>.Continuation?

    private var receivedDataStream: SharedAsyncSequence<AsyncThrowingStream<Data, Error>>?

    private var receivedDataContinuation: AsyncThrowingStream<Data, Error>.Continuation?

    private var isStarted = false

    private var receivingData = Data()

    private let semaphore = AsyncSemaphore(value: 1)

    private var messageHandlers: [String: MessageHandler] = [:]

    /// outgoing connection
    public init(endpoint: NWEndpoint) throws {
        Self.logger.info("RuntimeNetworkConnection outgoing endpoint: \(endpoint.debugDescription)")
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        self.connection = NWConnection(to: endpoint, using: parameters)
        try start()
    }

    /// incoming connection
    public init(connection: NWConnection) throws {
        Self.logger.info("RuntimeNetworkConnection incoming connection: \(connection.debugDescription)")
        self.connection = connection
        try start()
    }

    public func start() throws {
        guard !isStarted else { return }
        isStarted = true
        Self.logger.info("Connection will start")
        setupStreams()
        setupStateUpdateHandler()
        setupReceiver()
        observeIncomingMessages()
        connection.start(queue: queue)
        Self.logger.info("Connection did start")
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        Self.logger.info("Connection will stop")
        connection.stateUpdateHandler = nil
        connection.cancel()
        connectionStateContinuation?.finish()
        receivedDataContinuation?.finish()
        didStop?(self)
        didStop = nil
        Self.logger.info("Connection did stop")
    }

    public func setMessageHandler<Request: Codable, Response: Codable>(name: String, handler: @escaping ((Request) async throws -> Response)) {
        messageHandlers[name] = .init(closure: handler)
    }

    public func setMessageHandler<Request: RuntimeRequest>(_ handler: @escaping ((Request) async throws -> Request.Response)) {
        messageHandlers[Request.identifier] = .init(closure: handler)
    }

    public func send(requestData: RuntimeRequestData) async throws {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeNetworkConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
    }

    public func send<Response: Codable>(requestData: RuntimeRequestData) async throws -> Response {
        await semaphore.wait()
        defer { semaphore.signal() }
        logger.info("RuntimeNetworkConnection send identifier: \(requestData.identifier)")
        try await send(content: requestData)
        let receiveData = try await receiveData()
        let responseData = try JSONDecoder().decode(RuntimeRequestData.self, from: receiveData)
        logger.info("RuntimeNetworkConnection received identifier: \(responseData.identifier)")
        logger.info("RuntimeNetworkConnection received data: \(receiveData)")
        return try JSONDecoder().decode(Response.self, from: responseData.data)
    }

    public func send<Request: RuntimeRequest>(request: Request) async throws {
        let requestData = try RuntimeRequestData(request: request)
        try await send(requestData: requestData)
    }

    public func send<Request: RuntimeRequest>(request: Request) async throws -> Request.Response {
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
                        logger.info("RuntimeNetworkConnection received identifier: \(requestData.identifier)")
                        logger.info("RuntimeNetworkConnection received data: \(data)")
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

    private func stateDidChange(_ state: NWConnection.State) {
        switch state {
        case .setup:
            logger.info("Connection is setup")
        case .waiting(let error):
            logger.info("Connection is waiting, error: \(error)")
            stop()
        case .preparing:
            logger.info("Connection is preparing")
        case .ready:
            logger.info("Connection is ready")

            didReady?(self)
            didReady = nil
        case .failed(let error):
            logger.info("Connection is failed, error: \(error)")
            stop()
        case .cancelled:
            logger.info("Connection is cancelled")
        default:
            break
        }
    }

    private func setupStreams() {
        let (connectionStateStream, connectionStateContinuation) = AsyncStream<NWConnection.State>.makeStream()
        self.connectionStateStream = connectionStateStream
        self.connectionStateContinuation = connectionStateContinuation

        let (receivedDataStream, receivedDataContinuation) = AsyncThrowingStream<Data, Error>.makeStream()
        self.receivedDataStream = receivedDataStream.shared()
        self.receivedDataContinuation = receivedDataContinuation
    }

    private func setupStateUpdateHandler() {
        connection.stateUpdateHandler = { [weak self] in
            guard let self else { return }
            connectionStateContinuation?.yield($0)
            stateDidChange($0)
        }
    }

    private func setupReceiver() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Int.max) { [weak self] data, contentContext, isComplete, error in
            guard let self else { return }
            if let error {
                receivedDataContinuation?.finish(throwing: error)
                stop()
            } else if isComplete {
                receivedDataContinuation?.finish()
                stop()
            } else if let data = data {
                receivingData.append(data)
                processReceivedData(context: contentContext)
                setupReceiver()
            }
        }
    }

    private func processReceivedData(context: NWConnection.ContentContext? = nil) {
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
        try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<Void, Error>) in
            guard let self else {
                continuation.resume(throwing: RuntimeNetworkError.notConnected)
                return
            }

            connection.send(content: data + Self.endMarkerData, completion: .contentProcessed { error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                Self.logger.info("RuntimeNetworkConnection send data: \(data)")
                continuation.resume()
            })
        }
    }

    private func receiveData() async throws -> Data {
        guard let receivedDataStream else {
            throw RuntimeNetworkError.notConnected
        }

        for try await data in receivedDataStream {
            if let error = try? JSONDecoder().decode(RuntimeNetworkRequestError.self, from: data) {
                throw error
            } else {
                return data
            }
        }

        throw RuntimeNetworkError.receiveFailed
    }
}

private struct MessageNull: Codable {
    static let null = MessageNull()
}

class RuntimeNetworkBaseConnection: RuntimeConnection {
    var connection: RuntimeNetworkConnection?

    init() {}

    func sendMessage(name: String) async throws {
        guard let connection = connection else { throw RuntimeNetworkError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage(name: String, request: some Codable) async throws {
        guard let connection = connection else { throw RuntimeNetworkError.notConnected }
        try await connection.send(requestData: RuntimeRequestData(identifier: name, value: request))
    }

    func sendMessage<Response>(name: String) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeNetworkError.notConnected }
        return try await connection.send(requestData: RuntimeRequestData(identifier: name, value: MessageNull.null))
    }

    func sendMessage<Request>(request: Request) async throws -> Request.Response where Request: RuntimeRequest {
        guard let connection = connection else { throw RuntimeNetworkError.notConnected }
        return try await connection.send(request: request)
    }

    func sendMessage<Response>(name: String, request: some Codable) async throws -> Response where Response: Decodable, Response: Encodable {
        guard let connection = connection else { throw RuntimeNetworkError.notConnected }
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

final class RuntimeNetworkClientConnection: RuntimeNetworkBaseConnection {
    init(endpoint: RuntimeNetworkEndpoint) throws {
        super.init()
        self.connection = try RuntimeNetworkConnection(endpoint: endpoint.endpoint)
    }
}

final class RuntimeNetworkServerConnection: RuntimeNetworkBaseConnection {
    let listener: NWListener

    init(name: String) async throws {
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 2

        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        parameters.includePeerToPeer = true
        self.listener = try NWListener(using: parameters)
        super.init()
        listener.service = NWListener.Service(name: name, type: RuntimeNetworkBonjour.type)
        try await start()
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            listener.newConnectionHandler = { [weak self] newConnection in
                guard let self else { return }
                do {
                    let connection = try RuntimeNetworkConnection(connection: newConnection)
                    self.connection = connection
                    connection.didReady = { _ in
                        continuation.resume()
                    }
                    connection.didStop = { [weak self] _ in
                        guard let self else { return }
                        Task {
                            try await self.start()
                        }
                    }
                    listener.newConnectionHandler = nil
                    listener.cancel()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: .main)
        }
    }
}
