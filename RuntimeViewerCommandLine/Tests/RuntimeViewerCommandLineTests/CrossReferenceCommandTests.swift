import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import Testing
@testable import RuntimeViewerCommandLineInterface

/// `callers`, `callees`, `references` and `symbolicate` against the local
/// engine, with libobjc indexed: their results, and the JSON the MCP tools
/// share.
@Suite("Cross-reference commands", .serialized)
struct CrossReferenceCommandTests {
    private static let libobjcPath = TestLocalEngine.libobjcPath

    private func executor() async throws -> CommandExecutor {
        RuntimeCrossReferences.install()
        return CommandExecutor(sourceResolver: LocalSourceResolver(engine: try await TestLocalEngine.shared()))
    }

    @Test("The commands are new in protocol version 3; a version 2 host cannot decode them")
    func commandLineProtocolVersionIsThree() {
        #expect(CommandLineProtocol.version == 3)
    }

    /// `objc_storeStrong` calls `objc_release`, in libobjc itself.
    @Test("A callers result prints the fields the MCP tools' references have, every address a hexadecimal string")
    func callersCommandJSONMatchesTheMCPResponseFields() async throws {
        let result = try await executor().execute(.callers(CallersCommand(target: "_objc_release", image: Self.libobjcPath, scope: .image)))
        guard case .crossReferences(let references) = result else {
            Issue.record("expected cross references, got \(result)")
            return
        }
        #expect(!references.references.isEmpty)
        #expect(references.references.allSatisfy { $0.imagePath == Self.libobjcPath })

        let document = try #require(try JSONSerialization.jsonObject(with: Data(JSONRenderer.render(result).utf8)) as? [String: Any])
        let rows = try #require(document["references"] as? [[String: Any]])
        let rowKeys = try Self.encodedKeys(of: references.references[0])
        for row in rows {
            #expect(Set(row.keys).isSubset(of: rowKeys) && rowKeys.subtracting(["functionName", "functionSymbol"]).isSubset(of: Set(row.keys)))
            #expect((row["instructionAddress"] as? String)?.hasPrefix("0x") == true)
            #expect((row["functionAddress"] as? String)?.hasPrefix("0x") == true)
        }
        #expect(document["isComplete"] as? Bool == true)
    }

    @Test("Callees of a function name what it calls, in instruction order")
    func calleesListWhatAFunctionCalls() async throws {
        let result = try await executor().execute(.callees(CalleesCommand(target: "objc_storeStrong", image: Self.libobjcPath, includesRuntimeHelperCalls: true)))
        guard case .crossReferences(let references) = result else {
            Issue.record("expected cross references, got \(result)")
            return
        }
        #expect(references.references.contains { $0.target.contains("objc_release") })
        let sites = references.references.compactMap { UInt64($0.instructionAddress.dropFirst(2), radix: 16) }
        #expect(sites == sites.sorted())
    }

    @Test("Symbolicate works on the local source: a function and the offset into it, and an address nothing maps")
    func symbolicateCommandWorksOnTheLocalSource() async throws {
        let executor = try await executor()
        let callers = try await executor.execute(.callers(CallersCommand(target: "_objc_release", image: Self.libobjcPath, scope: .image, limit: 1)))
        guard case .crossReferences(let references) = callers, let reference = references.references.first,
              let site = UInt64(reference.instructionAddress.dropFirst(2), radix: 16)
        else {
            Issue.record("no caller to symbolicate")
            return
        }
        let result = try await executor.execute(.symbolicate(SymbolicateCommand(addresses: [site, 0x10], image: Self.libobjcPath)))
        guard case .symbolications(let symbolications) = result else {
            Issue.record("expected symbolications, got \(result)")
            return
        }
        #expect(symbolications.symbolications.count == 2)
        let first = symbolications.symbolications[0]
        #expect(first.kind == "function")
        #expect(first.functionAddress == reference.functionAddress)
        #expect(first.imagePath == Self.libobjcPath)
        #expect(first.summary.hasPrefix(reference.functionName ?? reference.functionSymbol ?? reference.functionAddress))
        #expect(symbolications.symbolications[1].kind == "unmapped")
        #expect(TextRenderer.render(result).output.contains("unmapped"))
    }

    @Test("A target nothing names, and an address without its image, are told apart")
    func unresolvedTargetsFailWithTheirCodes() async throws {
        let executor = try await executor()
        await #expect(throws: CommandFailure.self, performing: {
            _ = try await executor.execute(.callers(CallersCommand(target: "_NoSuchSymbolAnywhereAtAll", scope: .indexed)))
        })
        do {
            _ = try await executor.execute(.callers(CallersCommand(target: "_NoSuchSymbolAnywhereAtAll")))
        } catch let failure as CommandFailure {
            #expect(failure.code == .targetNotFound)
        }
        do {
            _ = try await executor.execute(.callees(CalleesCommand(target: "0x1000")))
            Issue.record("an address without its image resolved")
        } catch let failure as CommandFailure {
            #expect(failure.code == .invalidArgument)
            #expect(failure.message.contains("--image"))
        }
    }

    private static func encodedKeys(of row: RuntimeCrossReferenceRow) throws -> Set<String> {
        let encoder = JSONEncoder()
        let object = try JSONSerialization.jsonObject(with: try encoder.encode(row)) as? [String: Any]
        // An optional that is nil is left out: count the declared fields.
        return Set(object?.keys ?? [:].keys).union(["functionName", "functionSymbol"])
    }
}
