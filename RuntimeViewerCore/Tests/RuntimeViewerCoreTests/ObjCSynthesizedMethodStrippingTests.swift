import Testing
import Foundation
import RuntimeViewerCore

/// Regression coverage for `ObjCGenerationOptions.stripSynthesizedMethods`.
///
/// The option collected `setFoo` as the selector to remove, but a setter takes
/// an argument, so its real selector is `setFoo:`. Collected names are matched
/// against the method's full selector, so the option never stripped a single
/// setter — only getters, which are zero-argument and therefore spelled without
/// a colon. The mistake ran both ways: an unrelated zero-argument method named
/// `setFoo` would have been stripped instead of the accessor.
///
/// MachOObjCSection fixed its own copy of this code in `0.8.104`, and its
/// commit message called for exactly this follow-up: RuntimeViewer's ObjC dump
/// path does not run the upstream builder, so it carried the same bug in two
/// places — the class branch and the protocol branch of
/// `RuntimeObjCSection.interface(for:using:transformer:)`.
///
/// The tests search Foundation for a class that really declares a synthesized
/// setter rather than naming one, so they do not go stale when a system
/// framework's contents shift between OS releases.
@Suite("ObjC Synthesized Method Stripping")
struct ObjCSynthesizedMethodStrippingTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"

    /// How many classes to examine before giving up. Foundation declares
    /// thousands, and generating an interface is not free; a synthesized setter
    /// turns up far inside this bound.
    private static let classScanLimit = 60

    private static func makeEngine() async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-strip-synthesized-methods")
        try await engine.connect()
        try await engine.loadImage(at: foundationPath)
        return engine
    }

    /// Sorted by name: `objects(in:)` does not promise an order, and an
    /// unordered scan would let the two tests below land on different classes.
    private static func classObjects(in engine: RuntimeEngine) async throws -> [RuntimeObject] {
        let objects = try await engine.objects(in: foundationPath)
        return objects.filter { $0.kind == .objc(.type(.class)) }.sorted { $0.name < $1.name }
    }

    private static func options(strippingSynthesizedMethods: Bool) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.objcHeaderOptions.stripSynthesizedMethods = strippingSynthesizedMethods
        return options
    }

    private static func interfaceString(
        for object: RuntimeObject,
        strippingSynthesizedMethods: Bool,
        using engine: RuntimeEngine
    ) async throws -> String? {
        let interface = try await engine.interface(
            for: object,
            options: options(strippingSynthesizedMethods: strippingSynthesizedMethods)
        )
        return interface?.interfaceString.string
    }

    /// The names of properties whose accessors the dump synthesizes — the ones
    /// `stripSynthesizedMethods` is supposed to remove. Properties that name a
    /// custom `setter=` are excluded, because their setter selector is spelled
    /// out rather than derived, and `readonly` ones have no setter at all.
    private static func synthesizedSetterPropertyNames(in interfaceString: String) -> [String] {
        interfaceString
            .split(separator: "\n")
            .filter { $0.hasPrefix("@property") }
            .filter { !$0.contains("setter=") && !$0.contains("readonly") }
            .compactMap { line in
                guard let semicolonIndex = line.lastIndex(of: ";") else { return nil }
                let identifier = line[..<semicolonIndex]
                    .reversed()
                    .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    .reversed()
                return identifier.isEmpty ? nil : String(identifier)
            }
    }

    /// The selector the runtime really registers for a synthesized setter.
    /// `URL` must become `setURL:`, not `setUrl:`, so this uppercases the first
    /// character rather than capitalizing the word.
    private static func synthesizedSetterSelector(forPropertyNamed propertyName: String) -> String {
        "set" + propertyName.prefix(1).uppercased() + propertyName.dropFirst() + ":"
    }

    /// True when the interface declares a method whose selector starts with
    /// `selectorPrefix`.
    ///
    /// Matched at the selector's position — right after the return type's
    /// closing parenthesis — rather than anywhere in the text. A plain
    /// `contains` would count `+ (id)transformWithTransformStruct:(…)transformStruct;`
    /// as declaring `transformStruct`, because ObjC dumps spell the parameter
    /// name after the type and it often matches the property.
    private static func declaresMethod(withSelectorPrefix selectorPrefix: String, in interfaceString: String) -> Bool {
        interfaceString.split(separator: "\n").contains { line in
            let declaration = line.trimmingCharacters(in: .whitespaces)
            guard declaration.hasPrefix("- (") || declaration.hasPrefix("+ (") else { return false }
            guard let returnTypeEnd = declaration.firstIndex(of: ")") else { return false }
            return declaration[declaration.index(after: returnTypeEnd)...].hasPrefix(selectorPrefix)
        }
    }

    private struct SynthesizedSetterCase {
        let object: RuntimeObject
        let setterSelector: String
        let getterSelector: String
        let unstrippedInterface: String
    }

    /// Finds a class that declares a property together with the setter the
    /// runtime synthesized for it, so the assertions below test stripping
    /// rather than a selector typo.
    private static func findClassDeclaringASynthesizedSetter(using engine: RuntimeEngine) async throws -> SynthesizedSetterCase? {
        for object in try await classObjects(in: engine).prefix(classScanLimit) {
            guard let unstrippedInterface = try await interfaceString(
                for: object,
                strippingSynthesizedMethods: false,
                using: engine
            ) else { continue }

            for propertyName in synthesizedSetterPropertyNames(in: unstrippedInterface) {
                let setterSelector = synthesizedSetterSelector(forPropertyNamed: propertyName)
                guard declaresMethod(withSelectorPrefix: setterSelector, in: unstrippedInterface) else { continue }
                return SynthesizedSetterCase(
                    object: object,
                    setterSelector: setterSelector,
                    getterSelector: propertyName,
                    unstrippedInterface: unstrippedInterface
                )
            }
        }
        return nil
    }

    @Test("stripSynthesizedMethods removes the setter, not just the getter")
    func stripSynthesizedMethodsRemovesTheSetter() async throws {
        let engine = try await Self.makeEngine()
        let synthesizedSetterCase = try #require(
            await Self.findClassDeclaringASynthesizedSetter(using: engine),
            "no class among the first \(Self.classScanLimit) in Foundation declares a synthesized setter"
        )

        // Baseline: the setter really is in the unstripped output, so the
        // assertion below tests stripping rather than a selector typo.
        #expect(Self.declaresMethod(
            withSelectorPrefix: synthesizedSetterCase.setterSelector,
            in: synthesizedSetterCase.unstrippedInterface
        ))

        let strippedInterface = try #require(
            await Self.interfaceString(
                for: synthesizedSetterCase.object,
                strippingSynthesizedMethods: true,
                using: engine
            )
        )

        #expect(
            !Self.declaresMethod(withSelectorPrefix: synthesizedSetterCase.setterSelector, in: strippedInterface),
            "\(synthesizedSetterCase.object.name) kept \(synthesizedSetterCase.setterSelector) after stripping synthesized methods"
        )
    }

    /// The control case. Getters were the half that always worked, so a fix
    /// that spells the setter right must not cost them.
    @Test("stripSynthesizedMethods keeps removing the getter")
    func stripSynthesizedMethodsRemovesTheGetter() async throws {
        let engine = try await Self.makeEngine()
        let synthesizedSetterCase = try #require(
            await Self.findClassDeclaringASynthesizedSetter(using: engine),
            "no class among the first \(Self.classScanLimit) in Foundation declares a synthesized setter"
        )

        let strippedInterface = try #require(
            await Self.interfaceString(
                for: synthesizedSetterCase.object,
                strippingSynthesizedMethods: true,
                using: engine
            )
        )

        // A getter takes no argument, so its selector is the bare property name
        // followed straight by the declaration's semicolon.
        let getterDeclaration = "\(synthesizedSetterCase.getterSelector);"
        #expect(Self.declaresMethod(
            withSelectorPrefix: getterDeclaration,
            in: synthesizedSetterCase.unstrippedInterface
        ))
        #expect(!Self.declaresMethod(withSelectorPrefix: getterDeclaration, in: strippedInterface))
    }
}
