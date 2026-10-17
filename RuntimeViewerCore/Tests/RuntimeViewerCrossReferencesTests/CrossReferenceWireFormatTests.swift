import Testing
import Foundation
import RuntimeViewerCore
@testable import RuntimeViewerCrossReferences

/// The commands cross a process boundary between two builds — the app and an
/// XPC service, a host and an injected payload — so the names and the encoded
/// form are a contract, not an implementation detail.
@Suite("Cross-reference command wire format")
struct CrossReferenceWireFormatTests {
    @Test("Command names are the documented strings")
    func commandNames() {
        let prefix = "com.RuntimeViewer.RuntimeViewerCore.RuntimeEngine."
        #expect(RuntimeEngine.CommandName.crossReferenceCallees.commandName == prefix + "crossReferenceCallees")
        #expect(RuntimeEngine.CommandName.crossReferenceCallers.commandName == prefix + "crossReferenceCallers")
        #expect(RuntimeEngine.CommandName.crossReferenceTypeReferences.commandName == prefix + "crossReferenceTypeReferences")
    }

    @Test("Request types name their own command")
    func requestTypesNameTheirCommand() {
        #expect(RuntimeCrossReferences.CalleesCommand.commandName == RuntimeEngine.CommandName.crossReferenceCallees.commandName)
        #expect(RuntimeCrossReferences.CallersCommand.commandName == RuntimeEngine.CommandName.crossReferenceCallers.commandName)
        // Cancelling a caller must stop a scan of thousands of images where it
        // runs, not only where it was asked.
        #expect(RuntimeCrossReferences.CallersCommand.cancelsAcrossConnections)
        #expect(RuntimeCrossReferences.TypeReferencesCommand.commandName == RuntimeEngine.CommandName.crossReferenceTypeReferences.commandName)
        #expect(RuntimeCrossReferences.TypeReferencesCommand.cancelsAcrossConnections)
    }

    @Test("A type references request survives a round trip")
    func typeReferencesRequestRoundTrip() throws {
        let command = RuntimeCrossReferences.TypeReferencesCommand(
            object: RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", children: []),
            scope: .image(path: "/System/Library/Frameworks/SharedWithYou.framework/Versions/A/SharedWithYou"),
            options: RuntimeCrossReferenceQueryOptions(resultLimit: 50)
        )
        let decoded = try JSONDecoder().decode(RuntimeCrossReferences.TypeReferencesCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded.object == command.object)
        #expect(decoded.scope == command.scope)
        #expect(decoded.options == command.options)
    }

    @Test("A callers request survives a round trip")
    func callersRequestRoundTrip() throws {
        let command = RuntimeCrossReferences.CallersCommand(
            subject: .function(imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", address: 0x1_8AE3_35C0),
            scope: .allImages,
            options: RuntimeCrossReferenceQueryOptions(includesRuntimeHelperCalls: true, receiverClassName: "NSWindow", resultLimit: 200)
        )
        let decoded = try JSONDecoder().decode(RuntimeCrossReferences.CallersCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded.subject == command.subject)
        #expect(decoded.scope == command.scope)
        #expect(decoded.options == command.options)
    }

    @Test("Every subject survives a round trip", arguments: [
        RuntimeCrossReferenceSubject.function(imagePath: "/usr/lib/libobjc.A.dylib", address: 0x1_8000_1000),
        .selector("makeKeyAndOrderFront:"),
        .member(RuntimeMemberReference(
            object: RuntimeObject(name: "NSObject", displayName: "NSObject", kind: .objc(.type(.class)), imagePath: "/usr/lib/libobjc.A.dylib", children: []),
            name: "description",
            kind: .objcMethod,
            isStatic: false
        )),
    ])
    func subjectRoundTrip(_ subject: RuntimeCrossReferenceSubject) throws {
        #expect(try roundTrip(subject) == subject)
    }

    @Test("A result with every kind of target survives a round trip")
    func resultRoundTrip() throws {
        let caller = RuntimeFunctionReference(
            imagePath: "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            address: 0x1_8AE3_35C0,
            displayName: "-[NSWindow makeKeyAndOrderFront:]",
            symbolName: "-[NSWindow makeKeyAndOrderFront:]",
            member: nil,
            foldedSymbolCount: 0
        )
        let unnamed = RuntimeFunctionReference(imagePath: caller.imagePath, address: 0x1_8AE3_0000, displayName: nil, symbolName: nil, member: nil, foldedSymbolCount: 0)
        let targets: [RuntimeCrossReferenceTarget] = [
            .function(unnamed),
            .importedSymbol(name: "_CFRelease"),
            .selector(name: "orderWindow:relativeTo:", receiverClassName: "NSWindow"),
            .selector(name: "count", receiverClassName: nil),
            .type(name: "NSWindow", object: nil),
            .type(name: "URL", object: RuntimeObject(name: "10Foundation3URLV", displayName: "URL", kind: .swift(.type(.struct)), imagePath: "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation", children: [])),
            .indirect(tableOffset: 0x30, pointerAuthenticationConstant: 0x60F0),
            .unrecognizedCode(address: 0x1234),
        ]
        let result = RuntimeCrossReferenceQueryResult(
            references: targets.enumerated().map { index, target in
                RuntimeCrossReference(
                    referencingFunction: caller,
                    instructionAddress: caller.address + UInt64(index * 4),
                    kind: .call,
                    target: target,
                    precision: .exact,
                    isRuntimeHelperCall: false
                )
            },
            isComplete: false
        )
        #expect(try roundTrip(result) == result)
    }

    @Test("Every error says what went wrong, with what it was about")
    func errorsDescribeThemselves() {
        // A handler's thrown error reaches the host as its description only, so
        // every case must say what went wrong on its own, and name its subject.
        let errors: [(error: RuntimeCrossReferenceError, mentions: [String])] = [
            (.unsupportedArchitecture, ["arm64"]),
            (.imageNotFound(path: "/nowhere"), ["/nowhere"]),
            (.functionNotFound(imagePath: "/usr/lib/libobjc.A.dylib", address: 0x10), ["/usr/lib/libobjc.A.dylib", "0x10"]),
            (.memberNotFound(objectName: "NSObject", memberName: "nothing"), ["NSObject", "nothing"]),
            (.selectorHasNoCallees("count"), ["count"]),
            (.typeNotFound(objectName: "NSCopying"), ["NSCopying"]),
        ]
        for (error, mentions) in errors {
            let description = error.errorDescription ?? ""
            #expect(mentions.allSatisfy(description.contains), "\(description)")
        }
    }

    private func roundTrip<Value: Codable>(_ value: Value) throws -> Value {
        try JSONDecoder().decode(Value.self, from: JSONEncoder().encode(value))
    }
}
