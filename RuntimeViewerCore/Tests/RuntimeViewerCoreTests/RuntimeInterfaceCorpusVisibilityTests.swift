import Foundation
import Testing
@testable import RuntimeViewerCore

/// The Find corpus, read under some Generation Options, is the content pane's
/// text under them: each corpus entry, projected with the options a search
/// carries, equals the interface the engine prints for the content pane with
/// the same options. Checked for libobjc and Foundation — Objective-C
/// classes, protocols and categories, C structs, Swift types and extensions —
/// under the options a user may plausibly run with.
///
/// The corpus orders Swift members by category whatever the options say (a
/// reordering is not something a region expresses), so every option set
/// here does too.
@Suite("Find corpus under the Generation Options", .serialized)
struct RuntimeInterfaceCorpusVisibilityTests {
    private enum Anchors {
        static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Foundation"
        static let libobjcPath = "/usr/lib/libobjc.A.dylib"
    }

    private static func objcOptions(stripping: Bool, commenting: Bool) -> ObjCGenerationOptions {
        ObjCGenerationOptions(
            stripProtocolConformance: stripping,
            stripOverrides: stripping,
            stripSynthesizedIvars: stripping,
            stripSynthesizedMethods: stripping,
            stripCtorMethod: stripping,
            stripDtorMethod: stripping,
            addIvarOffsetComments: commenting,
            addPropertyAttributesComments: commenting,
            addMethodIMPAddressComments: commenting,
            addPropertyAccessorAddressComments: commenting
        )
    }

    /// Nothing extra; everything; what the user reported with (every strip
    /// and every detail on); and a mix that pulls the two halves apart.
    private static let optionSets: [(label: String, options: RuntimeObjectInterface.GenerationOptions)] = {
        let everythingOn = SwiftGenerationOptions(
            printStrippedSymbolicItem: true,
            printFieldOffset: true,
            printExpandedFieldOffset: true,
            printVTableOffset: true,
            printPWTOffset: true,
            printMemberAddress: true,
            printTypeLayout: true,
            printEnumLayout: true,
            synthesizeOpaqueType: true,
            memberSortOrder: .byCategory,
            infersObjCOverridesFromSelectorNames: true
        )
        let mixed = SwiftGenerationOptions(
            printStrippedSymbolicItem: false,
            printFieldOffset: true,
            printExpandedFieldOffset: false,
            printVTableOffset: false,
            printPWTOffset: true,
            printMemberAddress: false,
            printTypeLayout: true,
            printEnumLayout: false,
            synthesizeOpaqueType: false,
            memberSortOrder: .byCategory,
            infersObjCOverridesFromSelectorNames: true
        )
        return [
            ("defaults", RuntimeObjectInterface.GenerationOptions()),
            ("everything shown", RuntimeObjectInterface.GenerationOptions(objcHeaderOptions: objcOptions(stripping: false, commenting: true), swiftInterfaceOptions: everythingOn)),
            ("strips and details on", RuntimeObjectInterface.GenerationOptions(objcHeaderOptions: objcOptions(stripping: true, commenting: true), swiftInterfaceOptions: everythingOn)),
            ("mixed", RuntimeObjectInterface.GenerationOptions(objcHeaderOptions: objcOptions(stripping: true, commenting: false), swiftInterfaceOptions: mixed)),
        ]
    }()

    @Test("a projected corpus entry reads as the content pane's interface under the same options")
    func projectionMatchesTheDisplayedInterface() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "test-corpus-visibility")
        try await engine.connect()
        try await engine.loadImage(at: Anchors.libobjcPath)
        try await engine.loadImage(at: Anchors.foundationPath)
        defer { Task { await engine.stop() } }

        var mismatches: [String] = []
        var comparedCount = 0
        for imagePath in [Anchors.libobjcPath, Anchors.foundationPath] {
            _ = try await engine.buildInterfaceCorpus(for: imagePath, transformer: .default)
            let entries = try #require(await engine.interfaceCorpusStore.corpus(for: imagePath)?.entries)
            // Every Objective-C and C entry — cheap to print — and a spread of
            // the Swift ones, which are not.
            var swiftIndex = 0
            let sampledEntries = entries.filter { entry in
                guard entry.object.kind.isSwift else { return true }
                swiftIndex += 1
                return swiftIndex % 4 == 0
            }
            for (label, options) in Self.optionSets {
                let visibility = RuntimeInterfaceVisibility(options)
                for entry in sampledEntries {
                    guard let displayed = try await engine.interface(for: entry.object, options: options)?.interfaceString else { continue }
                    let projected = entry.projection(under: visibility)?.text ?? entry.interface
                    comparedCount += 1
                    if projected.string != displayed.string {
                        mismatches.append("\(entry.object.name) (\(entry.object.kind)) under \(label):\n\(projected.string)\n--- displayed ---\n\(displayed.string)")
                    } else if projected != displayed {
                        mismatches.append("\(entry.object.name) (\(entry.object.kind)) under \(label): same text, different spans or identifiers")
                    }
                    if mismatches.count >= 5 { break }
                }
                if mismatches.count >= 5 { break }
            }
        }
        #expect(comparedCount > 1000)
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n\n"))")
    }
}
