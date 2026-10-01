import Foundation
import Testing
import RuntimeViewerCore

/// A Swift protocol's interface prints each of its extensions once — the
/// default implementations included, which the printer itself already trails
/// a protocol without a parent type with. Checked over every Swift protocol
/// of Foundation, where `LocalizedError`'s default implementations have been
/// seen printed twice.
@Suite("Swift protocol interfaces", .serialized)
struct SwiftProtocolInterfaceTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
    }

    @Test("no protocol prints the same extension twice")
    func extensionsPrintedOnce() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-swift-protocol-interfaces")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.foundationPath)

        var protocols: [RuntimeObject] = []
        func collectProtocols(in objects: [RuntimeObject]) {
            for object in objects {
                if object.kind == .swift(.type(.protocol)) {
                    protocols.append(object)
                }
                collectProtocols(in: object.children)
            }
        }
        collectProtocols(in: try await engine.objects(in: Anchors.foundationPath))
        #expect(protocols.count > 20)

        var repeated: [String] = []
        for object in protocols {
            guard let interface = try await engine.interface(for: object, options: .mcp) else { continue }
            var seen: Set<String> = []
            for block in Self.extensionBlocks(of: interface.interfaceString.string) where !seen.insert(block).inserted {
                repeated.append("\(object.displayName): \(block.prefix(while: { $0 != "\n" }))")
            }
        }
        #expect(repeated.isEmpty, "\(repeated.count) extensions printed again, e.g.\n\(repeated.prefix(10).joined(separator: "\n"))")
    }

    /// Every block that starts with `extension` at the start of a line, up
    /// to the next one, trimmed — the unit the printer emits per extension
    /// definition.
    private static func extensionBlocks(of text: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("extension ") {
                if let current {
                    blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
                }
                current = [line]
            } else {
                current?.append(line)
            }
        }
        if let current {
            blocks.append(current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return blocks
    }
}
