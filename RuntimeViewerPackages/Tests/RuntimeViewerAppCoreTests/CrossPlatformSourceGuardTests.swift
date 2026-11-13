import Foundation
import Testing

/// The iOS, visionOS and jailbroken iOS apps compile these targets too,
/// and only the release job builds those apps — so code that compiles on
/// macOS alone has, more than once, been found by a failed release rather
/// than by a test. A macOS test run cannot compile for iOS, so this reads the
/// sources the way an iOS-family build does (`PackageSourceScan`): every `#if`
/// is evaluated for iOS and for visionOS, and whatever either of them would
/// compile is checked for
///
/// - imports of a module that links on macOS only — every module the package
///   manifest adds under `.when(platforms: appkitPlatforms)`, plus AppKit
///   itself — and
/// - uses of a dependency key these targets declare on macOS only, such as
///   `appRouter`.
///
/// It cannot see every macOS-only symbol: an AppKit type reached through a
/// re-export, or a member another module declares on macOS only, still takes
/// an iOS build to find.
@Suite("macOS-only code in the cross-platform targets")
struct CrossPlatformSourceGuardTests {
    private static let crossPlatformTargetNames = [
        "RuntimeViewerAppCore",
        "RuntimeViewerAppUI",
        "RuntimeViewerApplication",
        "RuntimeViewerArchitectures",
        "RuntimeViewerSettings",
        "RuntimeViewerUI",
    ]

    @Test(
        "nothing an iOS-family build compiles imports a macOS-only module or uses a macOS-only dependency key",
        arguments: crossPlatformTargetNames
    )
    func macOSOnlyCodeStaysInsideItsConditions(targetName: String) throws {
        let packageScan = try Self.packageScan.get()
        let macOSOnlyDependencyKeyNames = try Self.macOSOnlyDependencyKeyNames.get()
        var findings: [String] = []
        for sourceFile in packageScan.sourceFiles(inTargetNamed: targetName) {
            for line in sourceFile.lines where line.isCompiledForIOSFamily {
                if let moduleName = SwiftSourceText.importedModuleName(in: line.code),
                   packageScan.macOSOnlyModuleNames.contains(moduleName) {
                    findings.append("\(sourceFile.relativePath):\(line.number) imports \(moduleName)")
                }
                for dependencyKeyName in macOSOnlyDependencyKeyNames.sorted()
                    where SwiftSourceText.code(line.code, containsWord: dependencyKeyName) {
                    findings.append("\(sourceFile.relativePath):\(line.number) uses \(dependencyKeyName)")
                }
            }
        }
        #expect(
            findings.isEmpty,
            "an iOS-family build compiles these, and they exist on macOS only:\n\(findings.joined(separator: "\n"))"
        )
    }

    /// Without these the test above would pass by finding nothing to look for.
    @Test("the scan knows the modules and dependency keys it looks for, and reads every target")
    func scanKnowsWhatItLooksFor() throws {
        let packageScan = try Self.packageScan.get()
        #expect(packageScan.macOSOnlyModuleNames.isSuperset(of: ["AppKit", "RxAppKit", "CocoaCoordinator", "UIFoundationSettings"]))
        #expect(try Self.macOSOnlyDependencyKeyNames.get().contains("appRouter"))
        for targetName in Self.crossPlatformTargetNames {
            #expect(!packageScan.sourceFiles(inTargetNamed: targetName).isEmpty, "no sources read for \(targetName)")
        }
    }

    @Test(
        "a condition is read the way an iOS-family build reads it",
        arguments: [
            ("os(macOS)", false),
            ("!os(macOS)", true),
            ("canImport(AppKit) && !targetEnvironment(macCatalyst)", false),
            ("canImport(UIKit) && !targetEnvironment(macCatalyst) && !os(macOS)", true),
            ("canImport(RxAppKit)", false),
            ("os(macOS) || os(iOS)", true),
            ("os(macOS) || os(tvOS)", false),
            ("(os(macOS))", false),
            ("DEBUG", true),
            ("os(macOS) && DEBUG", false),
            ("canImport(RuntimeViewerSettings)", true),
        ]
    )
    func conditionIsReadForIOSFamily(condition: String, isCompiledForIOSFamily: Bool) {
        let parsedCondition = CompilationCondition.parse(condition)
        let macOSOnlyModuleNames: Set<String> = ["AppKit", "RxAppKit"]
        let isCompiled = ScannedPlatform.iOSFamily.contains { platform in
            parsedCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .unsatisfied
        }
        #expect(isCompiled == isCompiledForIOSFamily)
    }

    // MARK: - Reading the package

    private static let packageScan = Result { try PackageSourceScan.read(targetNames: crossPlatformTargetNames) }

    /// A key declared on macOS only, and nowhere an iOS-family build compiles, is one no iOS-family
    /// code may name.
    private static let macOSOnlyDependencyKeyNames = Result { () throws -> Set<String> in
        let scannedPackage = try packageScan.get()
        var dependencyKeyNamesCompiledForIOSFamily: Set<String> = []
        var dependencyKeyNamesCompiledForMacOSOnly: Set<String> = []
        for targetName in crossPlatformTargetNames {
            for sourceFile in scannedPackage.sourceFiles(inTargetNamed: targetName) {
                for declaration in sourceFile.dependencyKeyDeclarations {
                    if declaration.isCompiledForIOSFamily {
                        dependencyKeyNamesCompiledForIOSFamily.insert(declaration.name)
                    } else {
                        dependencyKeyNamesCompiledForMacOSOnly.insert(declaration.name)
                    }
                }
            }
        }
        return dependencyKeyNamesCompiledForMacOSOnly.subtracting(dependencyKeyNamesCompiledForIOSFamily)
    }
}

private struct DependencyKeyDeclaration {
    let name: String
    let isCompiledForIOSFamily: Bool
}

private extension ScannedSourceFile {
    /// The `var` each `@DependencyEntry` attribute declares, looked for on the attribute's own line
    /// and the few after it; and the `var` of each accessor written by hand over a key (`get {
    /// self[SomeKey.self] }`, the form a key takes when its live value lives in another module),
    /// looked for on the getter's line and the few before it.
    var dependencyKeyDeclarations: [DependencyKeyDeclaration] {
        var declarations: [DependencyKeyDeclaration] = []
        for (lineIndex, line) in lines.enumerated() where line.code.contains("@DependencyEntry") {
            for candidateLine in lines[lineIndex..<min(lineIndex + 4, lines.count)] {
                guard let name = Self.declaredVariableName(in: candidateLine.code) else { continue }
                declarations.append(DependencyKeyDeclaration(name: name, isCompiledForIOSFamily: candidateLine.isCompiledForIOSFamily))
                break
            }
        }
        for (lineIndex, line) in lines.enumerated() where line.code.contains("get { self[") && line.code.contains(".self]") {
            for candidateLine in lines[max(0, lineIndex - 3)..<lineIndex].reversed() {
                guard let name = Self.declaredVariableName(in: candidateLine.code) else { continue }
                declarations.append(DependencyKeyDeclaration(name: name, isCompiledForIOSFamily: candidateLine.isCompiledForIOSFamily))
                break
            }
        }
        return declarations
    }

    private static func declaredVariableName(in code: String) -> String? {
        let words = code.split(whereSeparator: { character in character.isWhitespace || character == ":" })
        guard let variableKeywordIndex = words.firstIndex(of: "var"), variableKeywordIndex + 1 < words.count else { return nil }
        return String(words[variableKeywordIndex + 1])
    }
}
