import Foundation
import Observation
import Testing
@testable import RuntimeViewerCore

// MARK: - Fixtures

/// A two-argument generic, nested into itself to make a field type long enough to break.
public struct MultilineTypeFormattingPair<First, Second> {
    public var first: First
    public var second: Second
}

/// A struct whose field type runs past a narrow width.
public struct MultilineTypeFormattingFixture {
    public var nested: MultilineTypeFormattingPair<MultilineTypeFormattingPair<Int, String>, MultilineTypeFormattingPair<Double, Bool>>
}

/// A class compiled from `@Observable` with a long field type, so a formatted interface still has
/// an attribute for the engine to place the expansion by.
@available(macOS 14.0, iOS 17.0, macCatalyst 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
@Observable
public final class MultilineTypeFormattingObservableFixture {
    public var pairs = MultilineTypeFormattingPair(first: MultilineTypeFormattingPair(first: 0, second: ""), second: 0.0)
}

// MARK: - Tests

/// Break Long Types on the engine (evolution proposal `multiline-type-formatting`): the Swift
/// section lays the interface's long types out over several lines with MachOSwiftSection's
/// `MultilineTypeFormatting` before it takes the marks out, so only whitespace changes; turning it
/// on or off regenerates the cached interface without reconfiguring the printer.
@Suite("Break Long Types on the engine", .serialized)
struct MultilineTypeFormattingEngineTests {
    private struct FixtureMissing: Error {}

    /// This test bundle's image, where the fixtures are declared.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private static let shared = Task<(engine: RuntimeEngine, objects: [RuntimeObject]), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "MultilineTypeFormattingEngineTests")
        try await engine.connect()
        return (engine, try await engine.objects(in: testBundlePath))
    }

    private static func fixture(named name: String) async throws -> RuntimeObject {
        let objects = try await shared.value.objects
        guard let fixture = objects.first(where: { object in
            object.kind.isSwift && (object.displayName == name || object.displayName.hasSuffix(".\(name)"))
        }) else {
            throw FixtureMissing()
        }
        return fixture
    }

    private static func options(breaksLongTypes: Bool, maximumLineWidth: Int = 60, marksAttachedMacros: Bool = false) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.breaksLongTypes = breaksLongTypes
        options.swiftInterfaceOptions.maximumLineWidth = maximumLineWidth
        options.marksAttachedMacros = marksAttachedMacros
        return options
    }

    private static func interfaceText(of name: String, _ options: RuntimeObjectInterface.GenerationOptions) async throws -> String {
        let engine = try await shared.value.engine
        let interface = try #require(try await engine.interface(for: fixture(named: name), options: options))
        return interface.interfaceString.string
    }

    private static func withoutWhitespace(_ text: String) -> String {
        text.filter { !$0.isWhitespace }
    }

    private static func lineCount(of text: String) -> Int {
        text.count { $0 == "\n" }
    }

    @Test func interfaceBreaksLongTypesWhenAsked() async throws {
        let plain = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: false))
        let formatted = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: true))

        #expect(plain.contains("MultilineTypeFormattingPair<Swift.Int, Swift.String>"))
        #expect(formatted.contains("MultilineTypeFormattingPair<\n"))
        #expect(Self.lineCount(of: formatted) > Self.lineCount(of: plain))
        #expect(Self.withoutWhitespace(formatted) == Self.withoutWhitespace(plain))
    }

    @Test func interfaceWithBreakLongTypesOffIsUnchanged() async throws {
        let defaultOptionsText = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", RuntimeObjectInterface.GenerationOptions())
        let narrowButOffText = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: false, maximumLineWidth: 10))
        #expect(narrowButOffText == defaultOptionsText)
    }

    @Test func togglingBreakLongTypesRegeneratesTheCachedInterface() async throws {
        let first = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: false))
        let formatted = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: true))
        let wider = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: true, maximumLineWidth: 1000))
        let last = try await Self.interfaceText(of: "MultilineTypeFormattingFixture", Self.options(breaksLongTypes: false))

        #expect(formatted != first)
        #expect(wider == first)
        #expect(last == first)
    }

    @Test func togglingBreakLongTypesKeepsThePrinter() async throws {
        let (engine, _) = try await Self.shared.value
        let fixture = try await Self.fixture(named: "MultilineTypeFormattingFixture")
        _ = try await engine.interface(for: fixture, options: Self.options(breaksLongTypes: false))
        let section = try #require(await engine.swiftSectionFactory.existingSection(for: fixture.imagePath) as? RuntimeSwiftSection<RuntimeLoadedImageReading>)
        let configurationUpdates = await section.printerConfigurationUpdateCount

        _ = try await engine.interface(for: fixture, options: Self.options(breaksLongTypes: true))
        _ = try await engine.interface(for: fixture, options: Self.options(breaksLongTypes: true, maximumLineWidth: 30))
        _ = try await engine.interface(for: fixture, options: Self.options(breaksLongTypes: false))

        #expect(await section.printerConfigurationUpdateCount == configurationUpdates)
    }

    @Test func macroExpansionsStillAttachToTheirTypeWhenFormatted() async throws {
        let engine = try await Self.shared.value.engine
        let fixture = try await Self.fixture(named: "MultilineTypeFormattingObservableFixture")
        let interface = try #require(try await engine.interface(for: fixture, options: Self.options(breaksLongTypes: true, maximumLineWidth: 40, marksAttachedMacros: true)))
        let text = interface.interfaceString.string
        let expansion = try #require(interface.macroExpansions?.first)

        #expect(text.contains("MultilineTypeFormattingPair<\n"))
        #expect(String(decoding: Array(text.utf8)[expansion.attributeUTF8Range], as: UTF8.self) == "@Observation.Observable")
        #expect(!expansion.parts.isEmpty)
    }
}
