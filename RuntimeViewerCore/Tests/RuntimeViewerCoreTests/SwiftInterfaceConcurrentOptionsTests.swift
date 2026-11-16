import Foundation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// Types with stored properties, so a print with field offsets differs from
/// one without, and with nested types and extensions, so each print is
/// several definitions and suspends between them.
public struct ConcurrentOptionsFixtureAlpha {
    public var first: Int = 0
    public var second: String = ""

    public struct Nested {
        public var value: Double = 0
        public var flag: Bool = false
    }
}

extension ConcurrentOptionsFixtureAlpha: Equatable {}

public final class ConcurrentOptionsFixtureBeta {
    public var identifier: Int = 0
    public var title: String = ""
    public var children: [ConcurrentOptionsFixtureBeta] = []

    public init() {}

    public struct Nested {
        public var depth: Int = 0
    }
}

extension ConcurrentOptionsFixtureBeta: CustomStringConvertible {
    public var description: String { title }
}

public struct ConcurrentOptionsFixtureGamma {
    public var lower: Int8 = 0
    public var upper: Int64 = 0
    public var name: String = ""

    public enum Kind {
        case small
        case large(Int)
    }
}

extension ConcurrentOptionsFixtureGamma: Hashable {}

// MARK: - Tests

/// What an image's Swift section prints when requests with different
/// Generation Options for it are in flight at the same time — the content
/// pane with the document's options, and MCP or the command-line tool with
/// their own, against one engine. Every request has to get the interface its
/// own options print, and nothing printed under one request's options may be
/// served to another's.
@Suite("Swift interfaces asked for concurrently with different options", .serialized)
struct SwiftInterfaceConcurrentOptionsTests {
    private struct FixtureMissing: Error {}

    /// This test bundle's image, where the fixtures are declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private static let fixtureNames = [
        "ConcurrentOptionsFixtureAlpha",
        "ConcurrentOptionsFixtureBeta",
        "ConcurrentOptionsFixtureGamma",
    ]

    /// One engine for the suite, and the fixtures as the sidebar lists them.
    private static let shared = Task<(engine: RuntimeEngine, fixtures: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "SwiftInterfaceConcurrentOptionsTests")
        try await engine.connect()
        let objects = try await engine.objects(in: testBundlePath)
        let fixtures = fixtureNames.compactMap { fixtureName in
            objects.first { object in
                object.kind.isSwift
                    && (object.displayName == fixtureName || object.displayName.hasSuffix(".\(fixtureName)"))
            }
        }
        guard fixtures.count == fixtureNames.count else { throw FixtureMissing() }
        return (engine, fixtures)
    }

    /// The two sets of options requests are made with: the plain one, and one
    /// that prints field offsets and member addresses and asks for the comment
    /// structure.
    private enum Variant: CaseIterable, Hashable, Sendable {
        case plain
        case detailed

        var options: RuntimeObjectInterface.GenerationOptions {
            var options = RuntimeObjectInterface.GenerationOptions()
            switch self {
            case .plain:
                options.swiftInterfaceOptions.printFieldOffset = false
                options.swiftInterfaceOptions.printMemberAddress = false
                options.marksCommentStructure = false
            case .detailed:
                options.swiftInterfaceOptions.printFieldOffset = true
                options.swiftInterfaceOptions.printMemberAddress = true
                options.marksCommentStructure = true
            }
            return options
        }
    }

    /// What a request got: the text, and whether it came with a comment
    /// structure.
    private struct Snapshot: Hashable, Sendable {
        let text: String
        let hasCommentStructure: Bool

        init(_ interface: RuntimeObjectInterface) {
            self.text = interface.interfaceString.string
            self.hasCommentStructure = interface.commentStructure != nil
        }
    }

    private struct ReferenceKey: Hashable {
        let fixtureName: String
        let variant: Variant
    }

    private static let roundCount = 25

    @Test("each request gets the interface its own options print, however the requests interleave")
    func concurrentRequestsKeepTheirOwnOptions() async throws {
        let (engine, fixtures) = try await Self.shared.value

        // Printed one at a time, so nothing else can reconfigure the printer.
        var references: [ReferenceKey: Snapshot] = [:]
        for fixture in fixtures {
            for variant in Variant.allCases {
                let interface = try #require(try await engine.interface(for: fixture, options: variant.options))
                references[ReferenceKey(fixtureName: fixture.name, variant: variant)] = Snapshot(interface)
            }
        }
        // Without a difference between the two prints the test proves nothing.
        try #require(fixtures.contains { fixture in
            references[ReferenceKey(fixtureName: fixture.name, variant: .plain)]?.text
                != references[ReferenceKey(fixtureName: fixture.name, variant: .detailed)]?.text
        })

        var mismatchCount = 0
        for _ in 0 ..< Self.roundCount {
            try await withThrowingTaskGroup(of: (ReferenceKey, Snapshot).self) { group in
                for fixture in fixtures {
                    for variant in Variant.allCases {
                        group.addTask {
                            let interface = try #require(try await engine.interface(for: fixture, options: variant.options))
                            return (ReferenceKey(fixtureName: fixture.name, variant: variant), Snapshot(interface))
                        }
                    }
                }
                for try await (key, snapshot) in group where snapshot != references[key] {
                    mismatchCount += 1
                }
            }
        }

        #expect(mismatchCount == 0, "\(mismatchCount) concurrent requests got an interface printed with other options")
    }
}
