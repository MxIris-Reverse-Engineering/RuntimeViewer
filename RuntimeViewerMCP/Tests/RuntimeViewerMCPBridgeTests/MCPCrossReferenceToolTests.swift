import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerCrossReferences
@testable import RuntimeViewerMCPBridge

/// The Callers, Callees, TypeReferences and Symbolicate tools: how long a
/// call waits, what it answers then, and the fields it shares with the
/// command line.
@Suite("Cross-reference tools")
struct MCPCrossReferenceToolTests {
    private static let reference = RuntimeCrossReference(
        referencingFunction: RuntimeFunctionReference(imagePath: "/usr/lib/libobjc.A.dylib", address: 0x1_8000_0000, displayName: "objc_storeStrong", symbolName: "_objc_storeStrong", member: nil, foldedSymbolCount: 0),
        instructionAddress: 0x1_8000_0010,
        kind: .tailCall,
        target: .importedSymbol(name: "_objc_release"),
        precision: .exact,
        isRuntimeHelperCall: true
    )

    @Test("A call that runs out of time answers with what the scan reported so far, incomplete — after 30 seconds by default")
    func callersToolReturnsAPartialResultAfterThirtySeconds() async throws {
        #expect(MCPBridgeServer.defaultCrossReferenceTimeLimit == .seconds(30))

        let outcome = try await MCPBridgeServer.references(within: .milliseconds(200)) { reportProgress in
            await reportProgress(RuntimeCrossReferenceQueryProgress(scannedImageCount: 1, totalImageCount: 2, references: [Self.reference]))
            try await Task.sleep(for: .seconds(30))
            return RuntimeCrossReferenceQueryResult(references: [], isComplete: true)
        }
        #expect(outcome.didRunOutOfTime)
        #expect(!outcome.isComplete)
        #expect(outcome.references == [Self.reference])

        let finished = try await MCPBridgeServer.references(within: .seconds(30)) { _ in
            RuntimeCrossReferenceQueryResult(references: [Self.reference], isComplete: true)
        }
        #expect(!finished.didRunOutOfTime)
        #expect(finished.isComplete)
        #expect(finished.references == [Self.reference])
    }

    @Test("Symbolicate answers for a window, and an unknown window is an error")
    func symbolicateToolRequiresAWindowIdentifier() async throws {
        let server = MCPBridgeServer(documentProvider: MockMCPBridgeDocumentProvider())
        await #expect(throws: MCPBridgeDocumentProviderError.self) {
            _ = try await server.symbolicate(windowIdentifier: "no-such-window", addresses: ["0x10"])
        }
    }

    @Test("A reference and a symbolication carry the command line's fields")
    func toolRowsHaveTheCommandLineFields() throws {
        let row = RuntimeCrossReferenceRow(Self.reference)
        #expect(try Self.keys(of: MCPCrossReferenceInfo(row)) == Self.keys(of: row))

        let symbolication = RuntimeAddressSymbolicationRow(RuntimeAddressSymbolication(
            address: 0x1_8000_0010,
            imagePath: "/usr/lib/libobjc.A.dylib",
            segmentName: "__TEXT",
            sectionName: "__text",
            kind: .function,
            function: Self.reference.referencingFunction,
            offset: 0x10,
            summary: "objc_storeStrong+0x10"
        ))
        #expect(try Self.keys(of: MCPAddressSymbolicationInfo(symbolication)) == Self.keys(of: symbolication))
    }

    private static func keys(of value: some Encodable) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]
        return Set(object?.keys ?? [:].keys)
    }
}
