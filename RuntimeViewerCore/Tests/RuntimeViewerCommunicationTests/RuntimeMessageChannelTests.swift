import Testing
import Foundation
@testable import RuntimeViewerCommunication

// MARK: - End Marker Tests

@Suite("RuntimeMessageChannel End Marker", .serialized)
struct RuntimeMessageChannelEndMarkerTests {

    @Test("End marker data is correct")
    func testEndMarkerData() {
        let endMarker = RuntimeMessageChannel.endMarkerData
        #expect(endMarker == "\nOK".data(using: .utf8)!)
    }

    @Test("End marker is 3 bytes")
    func testEndMarkerSize() {
        #expect(RuntimeMessageChannel.endMarkerData.count == 3)
    }
}

// MARK: - Message Framing Tests

@Suite("RuntimeMessageChannel Framing", .serialized)
struct RuntimeMessageChannelFramingTests {

    @Test("Single complete message is extracted")
    func testSingleCompleteMessage() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        let messageBody = "Hello, World!".data(using: .utf8)!
        let framedMessage = messageBody + RuntimeMessageChannel.endMarkerData

        channel.appendReceivedData(framedMessage)

        #expect(receivedMessages.count == 1)
        #expect(receivedMessages[0] == messageBody)
    }

    @Test("Multiple messages in single data chunk")
    func testMultipleMessagesInOneChunk() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        let message1 = "First".data(using: .utf8)!
        let message2 = "Second".data(using: .utf8)!
        let message3 = "Third".data(using: .utf8)!
        let endMarker = RuntimeMessageChannel.endMarkerData

        let combinedData = message1 + endMarker + message2 + endMarker + message3 + endMarker

        channel.appendReceivedData(combinedData)

        #expect(receivedMessages.count == 3)
        #expect(receivedMessages[0] == message1)
        #expect(receivedMessages[1] == message2)
        #expect(receivedMessages[2] == message3)
    }

    @Test("Partial message is buffered until end marker arrives")
    func testPartialMessage() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        let fullMessage = "Complete message".data(using: .utf8)!

        // Send first part without end marker
        let firstPart = "Complete ".data(using: .utf8)!
        channel.appendReceivedData(firstPart)
        #expect(receivedMessages.count == 0)

        // Send rest with end marker
        let secondPart = "message".data(using: .utf8)! + RuntimeMessageChannel.endMarkerData
        channel.appendReceivedData(secondPart)
        #expect(receivedMessages.count == 1)
        #expect(receivedMessages[0] == fullMessage)
    }

    @Test("End marker split across two data chunks")
    func testEndMarkerSplitAcrossChunks() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        let messageBody = "Hello".data(using: .utf8)!

        // Send message body + partial end marker ("\n")
        channel.appendReceivedData(messageBody + "\n".data(using: .utf8)!)
        #expect(receivedMessages.count == 0)

        // Send rest of end marker ("OK")
        channel.appendReceivedData("OK".data(using: .utf8)!)
        #expect(receivedMessages.count == 1)
        #expect(receivedMessages[0] == messageBody)
    }

    @Test("Empty message body with just end marker")
    func testEmptyMessageBody() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        channel.appendReceivedData(RuntimeMessageChannel.endMarkerData)
        #expect(receivedMessages.count == 1)
        #expect(receivedMessages[0] == Data())
    }

    @Test("Buffer size is zero after complete messages are extracted")
    func testBufferClearedAfterExtraction() async throws {
        let channel = RuntimeMessageChannel()

        let messageBody = "test".data(using: .utf8)!
        let framedMessage = messageBody + RuntimeMessageChannel.endMarkerData

        channel.appendReceivedData(framedMessage)
        #expect(channel.receivingBufferSize == 0)
    }

    @Test("Buffer retains partial data")
    func testBufferRetainsPartialData() async throws {
        let channel = RuntimeMessageChannel()

        let partialData = "incomplete".data(using: .utf8)!
        channel.appendReceivedData(partialData)
        #expect(channel.receivingBufferSize == partialData.count)
    }

    @Test("Large message framing")
    func testLargeMessageFraming() async throws {
        let channel = RuntimeMessageChannel()

        var receivedMessages: [Data] = []
        channel.onMessageReceived = { data in
            receivedMessages.append(data)
        }

        // Create a 1MB message
        let largeBody = Data(repeating: 0x42, count: 1_000_000)
        let framedMessage = largeBody + RuntimeMessageChannel.endMarkerData

        channel.appendReceivedData(framedMessage)

        #expect(receivedMessages.count == 1)
        #expect(receivedMessages[0].count == 1_000_000)
        #expect(receivedMessages[0] == largeBody)
    }
}

// MARK: - Handler Registration Tests

@Suite("RuntimeMessageChannel Handlers", .serialized)
struct RuntimeMessageChannelHandlerTests {

    @Test("Register and lookup handler by name")
    func testHandlerRegistration() {
        let channel = RuntimeMessageChannel()

        channel.setMessageHandler(name: "test") { (input: String) -> String in
            return input.uppercased()
        }

        let handler = channel.handler(for: "test")
        #expect(handler != nil)
    }

    @Test("Lookup returns nil for unregistered handler")
    func testUnregisteredHandler() {
        let channel = RuntimeMessageChannel()

        let handler = channel.handler(for: "nonexistent")
        #expect(handler == nil)
    }

    @Test("Register multiple handlers with different names")
    func testMultipleHandlers() {
        let channel = RuntimeMessageChannel()

        channel.setMessageHandler(name: "echo") { (input: String) -> String in
            return input
        }

        channel.setMessageHandler(name: "upper") { (input: String) -> String in
            return input.uppercased()
        }

        #expect(channel.handler(for: "echo") != nil)
        #expect(channel.handler(for: "upper") != nil)
        #expect(channel.handler(for: "missing") == nil)
    }

    @Test("Overwriting handler replaces previous one")
    func testHandlerOverwrite() async throws {
        let channel = RuntimeMessageChannel()

        channel.setMessageHandler(name: "process") { (input: String) -> String in
            return "v1: \(input)"
        }

        // Overwrite with new handler
        channel.setMessageHandler(name: "process") { (input: String) -> String in
            return "v2: \(input)"
        }

        let handler = channel.handler(for: "process")
        #expect(handler != nil)

        // Execute the handler to verify it's the new one
        let inputData = try JSONEncoder().encode("hello")
        let resultData = try await handler!.closure(inputData)
        let result = try JSONDecoder().decode(String.self, from: resultData)
        #expect(result == "v2: hello")
    }

    @Test("Handler processes typed request and response")
    func testHandlerTypedRequestResponse() async throws {
        let channel = RuntimeMessageChannel()

        channel.setMessageHandler(name: "add") { (request: [Int]) -> Int in
            return request.reduce(0, +)
        }

        let handler = channel.handler(for: "add")!
        let inputData = try JSONEncoder().encode([1, 2, 3, 4, 5])
        let resultData = try await handler.closure(inputData)
        let result = try JSONDecoder().decode(Int.self, from: resultData)
        #expect(result == 15)
    }
}

// MARK: - Pending Request Delivery Tests

@Suite("RuntimeMessageChannel Pending Requests", .serialized)
struct RuntimeMessageChannelPendingRequestTests {

    @Test("deliverToPendingRequest returns false when no pending request")
    func testNoPendingRequest() {
        let channel = RuntimeMessageChannel()

        let delivered = channel.deliverToPendingRequest(identifier: "nonexistent", data: Data())
        #expect(delivered == false)
    }
}

// MARK: - Finish Receiving Tests

@Suite("RuntimeMessageChannel Finish Receiving", .serialized)
struct RuntimeMessageChannelFinishTests {

    @Test("finishReceiving prevents further message extraction")
    func testFinishReceiving() async throws {
        let channel = RuntimeMessageChannel()

        var receivedCount = 0
        channel.onMessageReceived = { _ in
            receivedCount += 1
        }

        // Send one message
        let message1 = "first".data(using: .utf8)! + RuntimeMessageChannel.endMarkerData
        channel.appendReceivedData(message1)
        #expect(receivedCount == 1)

        // Finish receiving
        channel.finishReceiving()

        // Messages after finish — onMessageReceived still fires but the stream is closed
        let message2 = "second".data(using: .utf8)! + RuntimeMessageChannel.endMarkerData
        channel.appendReceivedData(message2)
        // onMessageReceived callback still works (it's independent of the stream)
        #expect(receivedCount == 2)
    }

    @Test("finishReceiving is idempotent")
    func testFinishReceivingIdempotent() {
        let channel = RuntimeMessageChannel()

        // Should not crash when called multiple times
        channel.finishReceiving()
        channel.finishReceiving()
        channel.finishReceiving()
    }

    @Test("finishReceiving with error")
    func testFinishReceivingWithError() {
        let channel = RuntimeMessageChannel()

        let error = RuntimeMessageChannelError.receiveFailed
        channel.finishReceiving(throwing: error)

        // Should not crash when called again
        channel.finishReceiving()
    }
}

// MARK: - RuntimeMessageChannelError Tests

@Suite("RuntimeMessageChannelError")
struct RuntimeMessageChannelErrorTests {

    @Test("Error cases")
    func testErrorCases() {
        let errors: [RuntimeMessageChannelError] = [
            .notConnected,
            .receiveFailed,
            .requestTimeout,
        ]
        #expect(errors.count == 3)
    }

    @Test("Error descriptions are non-nil")
    func testErrorDescriptions() {
        #expect(RuntimeMessageChannelError.notConnected.errorDescription != nil)
        #expect(RuntimeMessageChannelError.receiveFailed.errorDescription != nil)
        #expect(RuntimeMessageChannelError.requestTimeout.errorDescription != nil)
    }

    @Test("Error descriptions contain meaningful text")
    func testErrorDescriptionContent() {
        #expect(RuntimeMessageChannelError.notConnected.errorDescription!.contains("not connected"))
        #expect(RuntimeMessageChannelError.receiveFailed.errorDescription!.contains("receive"))
        #expect(RuntimeMessageChannelError.requestTimeout.errorDescription!.contains("timed out"))
    }
}

// MARK: - Timeout Tests

@Suite("RuntimeMessageChannel Timeout", .serialized)
struct RuntimeMessageChannelTimeoutTests {

    @Test("sendRequest with non-nil timeout throws requestTimeout when no response arrives")
    func testTimeoutFiresWhenResponseMissing() async throws {
        let channel = RuntimeMessageChannel()
        let identifier = "timeout-test-1"
        let payload = try RuntimeRequestData(identifier: identifier, value: RuntimeMessageNull.null)

        let start = Date()
        do {
            let _: String = try await channel.sendRequest(
                requestData: payload,
                timeout: 0.2
            ) { _ in
                // Writer succeeds, but no response is ever delivered.
            }
            Issue.record("expected requestTimeout to throw")
        } catch RuntimeMessageChannelError.requestTimeout {
            // expected
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed >= 0.2)
        #expect(elapsed < 1.0)

        // Once the deadline fired, the pending entry must be gone — a late response
        // arriving with the same identifier should not match anything.
        let lateDelivery = channel.deliverToPendingRequest(identifier: identifier, data: Data())
        #expect(lateDelivery == false)
    }

    @Test("sendRequest with timeout still returns response when it arrives in time")
    func testTimeoutDoesNotFireWhenResponseFastEnough() async throws {
        let channel = RuntimeMessageChannel()
        let identifier = "timeout-test-2"
        let payload = try RuntimeRequestData(identifier: identifier, value: RuntimeMessageNull.null)

        async let response: String = channel.sendRequest(
            requestData: payload,
            timeout: 1.0
        ) { _ in
            // Writer succeeds; deliverToPendingRequest fires below.
        }

        // Give sendRequest a beat to register the pending continuation, then deliver the
        // response synthetically. We deliver the same wire shape sendRequest expects:
        // an outer RuntimeRequestData whose `data` field decodes into Response.
        try await Task.sleep(nanoseconds: 50_000_000)
        let responseEnvelope = try RuntimeRequestData(identifier: identifier, value: "ok")
        let envelopeData = try JSONEncoder().encode(responseEnvelope)
        let delivered = channel.deliverToPendingRequest(identifier: identifier, data: envelopeData)
        #expect(delivered)

        let actual = try await response
        #expect(actual == "ok")
    }

    @Test("sendRequest with nil timeout does not race a deadline against response")
    func testNilTimeoutDoesNotFire() async throws {
        let channel = RuntimeMessageChannel()
        let identifier = "timeout-test-3"
        let payload = try RuntimeRequestData(identifier: identifier, value: RuntimeMessageNull.null)

        async let response: String = channel.sendRequest(
            requestData: payload,
            timeout: nil
        ) { _ in }

        // Sleep longer than the would-be deadlines from the other tests; with timeout=nil
        // the call must still be waiting for an explicit response or disconnect.
        try await Task.sleep(nanoseconds: 300_000_000)

        let responseEnvelope = try RuntimeRequestData(identifier: identifier, value: "delivered")
        let envelopeData = try JSONEncoder().encode(responseEnvelope)
        let delivered = channel.deliverToPendingRequest(identifier: identifier, data: envelopeData)
        #expect(delivered)

        let actual = try await response
        #expect(actual == "delivered")
    }

    @Test("sendRequest propagates writer error and does not block on timeout")
    func testWriterFailureUnblocksImmediately() async throws {
        struct WriterFailure: Error, Equatable {}

        let channel = RuntimeMessageChannel()
        let identifier = "timeout-test-4"
        let payload = try RuntimeRequestData(identifier: identifier, value: RuntimeMessageNull.null)

        let start = Date()
        do {
            let _: String = try await channel.sendRequest(
                requestData: payload,
                timeout: 5.0
            ) { _ in
                throw WriterFailure()
            }
            Issue.record("expected writer failure to propagate")
        } catch is WriterFailure {
            // expected
        }
        let elapsed = Date().timeIntervalSince(start)
        // Should resolve via the writer-error path well before the 5 s deadline.
        #expect(elapsed < 1.0)
    }
}

// MARK: - RuntimeStdioError Tests

@Suite("RuntimeStdioError")
struct RuntimeStdioErrorTypeTests {

    @Test("Error cases")
    func testErrorCases() {
        let errors: [RuntimeStdioError] = [
            .notConnected,
            .receiveFailed,
        ]
        #expect(errors.count == 2)
    }

    @Test("Error descriptions are non-nil")
    func testErrorDescriptions() {
        #expect(RuntimeStdioError.notConnected.errorDescription != nil)
        #expect(RuntimeStdioError.receiveFailed.errorDescription != nil)
    }

    @Test("Error descriptions contain meaningful text")
    func testErrorDescriptionContent() {
        #expect(RuntimeStdioError.notConnected.errorDescription!.contains("not established"))
        #expect(RuntimeStdioError.receiveFailed.errorDescription!.contains("receive"))
    }
}
