import Foundation
import Testing

/// The app targets hold no view model (proposal `view-models-to-app-core` for the macOS app,
/// `window-model-on-ios` for the iOS-family apps): every ViewModel and cell ViewModel is
/// RuntimeViewerAppCore's, where a test can build and drive it; an app keeps the view controllers,
/// coordinators, lifecycle controllers and the views bound to RuntimeViewerAppCore's types. The
/// compiler does not hold the apps to this, so this reads each app target's sources — comments and
/// strings left out — and reports, file and line,
///
/// - a type declared with a name ending in `ViewModel`, and
/// - a type whose inheritance clause names `ViewModel<…>`, `CellViewModel` or `ViewModelProtocol`.
///
/// A generic parameter or an associated type named `ViewModel`, as a view controller declares, is no
/// view model and passes.
@Suite("The app targets hold no view model")
struct AppTargetBoundaryTests {
    /// An app target whose sources the checks read.
    struct AppTarget: Sendable, CustomTestStringConvertible {
        /// The target's source folder, from the repository's root.
        let relativePath: String
        /// Fewer Swift files than this means the scan reads the wrong place.
        let minimumSourceFileCount: Int
        /// View models the target still declares because a later step moves them, by name. An entry
        /// whose view model is gone fails, so the exception goes with it.
        let viewModelsAwaitingTheirMove: Set<String>

        var directoryURL: URL {
            PackageSourceScan.repositoryDirectoryURL.appendingPathComponent(relativePath, isDirectory: true)
        }

        var testDescription: String { relativePath }
    }

    static let appTargets: [AppTarget] = [
        AppTarget(relativePath: "RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit", minimumSourceFileCount: 50, viewModelsAwaitingTheirMove: []),
        // The source folder of the iOS, jailbroken iOS and visionOS apps. Its empty MainViewModel merges
        // into RuntimeViewerAppCore's in step four of the iOS feature parity vision, with MainRoute.
        AppTarget(relativePath: "RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit", minimumSourceFileCount: 15, viewModelsAwaitingTheirMove: ["MainViewModel"]),
    ]

    private static let viewModelBaseNames: Set<String> = ["ViewModel", "CellViewModel", "ViewModelProtocol"]

    /// `class`, `struct`, `enum`, `actor`, `protocol` or `typealias`, then the declared name.
    private static let declarationPattern = #"\b(?:class|struct|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    /// A type declaration, its generic parameters skipped, then its inheritance clause up to the body or
    /// a `where` clause.
    private static let inheritancePattern = #"\b(?:class|struct|enum|actor)\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:<[^{]*?>)?\s*:\s*([^{]*)"#

    @Test("the app target's sources are where the scan reads them", arguments: appTargets)
    func appTargetDirectoryExists(_ appTarget: AppTarget) throws {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: appTarget.directoryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(appTarget.relativePath) is not where the scan looks; the checks below would pass by reading nothing")
        let sourceFiles = try PackageSourceScan.sourceFiles(inDirectory: appTarget.directoryURL)
        #expect(sourceFiles.count >= appTarget.minimumSourceFileCount, "only \(sourceFiles.count) Swift files read from \(appTarget.relativePath)")
    }

    @Test("no type in the app target is named as a view model", arguments: appTargets)
    func appTargetDeclaresNoViewModel(_ appTarget: AppTarget) throws {
        let declarationRegex = try Regex(Self.declarationPattern)
        var findings: [String] = []
        var viewModelsStillAwaitingTheirMove: Set<String> = []
        for sourceFile in try PackageSourceScan.sourceFiles(inDirectory: appTarget.directoryURL) {
            for line in sourceFile.lines {
                for match in line.code.matches(of: declarationRegex) {
                    guard let nameRange = match.output[1].range else { continue }
                    let name = String(line.code[nameRange])
                    guard name.hasSuffix("ViewModel") else { continue }
                    if appTarget.viewModelsAwaitingTheirMove.contains(name) {
                        viewModelsStillAwaitingTheirMove.insert(name)
                    } else {
                        findings.append("\(sourceFile.relativePath):\(line.number) declares \(name)")
                    }
                }
            }
        }
        #expect(findings.isEmpty, "view models go in RuntimeViewerAppCore (RuntimeViewerPackages/Sources/AGENTS.md):\n\(findings.joined(separator: "\n"))")
        #expect(viewModelsStillAwaitingTheirMove == appTarget.viewModelsAwaitingTheirMove, "moved out, so take the exception away: \(appTarget.viewModelsAwaitingTheirMove.subtracting(viewModelsStillAwaitingTheirMove).sorted())")
    }

    @Test("no type in the app target inherits a view model base", arguments: appTargets)
    func appTargetInheritsNoViewModel(_ appTarget: AppTarget) throws {
        let declarationRegex = try Regex(Self.declarationPattern)
        let inheritanceRegex = try Regex(Self.inheritancePattern)
        var findings: [String] = []
        for sourceFile in try PackageSourceScan.sourceFiles(inDirectory: appTarget.directoryURL) {
            for line in sourceFile.lines {
                guard let match = line.code.firstMatch(of: inheritanceRegex),
                      let clauseRange = match.output[1].range
                else { continue }
                // A view model waiting for its move inherits a view model base, as it should.
                if let declaration = line.code.firstMatch(of: declarationRegex),
                   let nameRange = declaration.output[1].range,
                   appTarget.viewModelsAwaitingTheirMove.contains(String(line.code[nameRange])) {
                    continue
                }
                var clause = Substring(line.code[clauseRange])
                if let whereRange = clause.range(of: " where ") {
                    clause = clause[..<whereRange.lowerBound]
                }
                for baseName in Self.inheritedTypeNames(in: clause) where Self.viewModelBaseNames.contains(baseName) {
                    findings.append("\(sourceFile.relativePath):\(line.number) inherits \(baseName)")
                }
            }
        }
        #expect(findings.isEmpty, "view models go in RuntimeViewerAppCore (RuntimeViewerPackages/Sources/AGENTS.md):\n\(findings.joined(separator: "\n"))")
    }

    @Test("the inheritance check reads a type's own clause, not its generic parameters or arguments")
    func inheritanceClauseIsReadAsDeclared() {
        #expect(Self.inheritedTypeNames(in: "BaseViewController<MCPStatusPopoverViewModel<MainRoute>>, Delegate") == ["BaseViewController", "Delegate"])
        #expect(Self.inheritedTypeNames(in: "RuntimeViewerAppCore.ViewModel<MainRoute>") == ["ViewModel"])
        #expect(Self.inheritedTypeNames(in: "CellViewModel, @unchecked Sendable") == ["CellViewModel", "Sendable"])
    }

    /// The names of the types an inheritance clause lists, each without its generic arguments, module
    /// or attributes: `BaseViewController<MainViewModel>, Delegate` lists `BaseViewController` and
    /// `Delegate`.
    private static func inheritedTypeNames(in clause: Substring) -> [String] {
        var entries: [String] = []
        var currentEntry = ""
        var genericDepth = 0
        for character in clause {
            switch character {
            case "<":
                genericDepth += 1
                currentEntry.append(character)
            case ">":
                genericDepth -= 1
                currentEntry.append(character)
            case "," where genericDepth == 0:
                entries.append(currentEntry)
                currentEntry = ""
            default:
                currentEntry.append(character)
            }
        }
        entries.append(currentEntry)
        return entries.compactMap { entry in
            let words = entry.split(separator: " ").filter { !$0.hasPrefix("@") }
            guard let typeName = words.first else { return nil }
            let withoutGenericArguments = typeName.split(separator: "<").first ?? typeName
            let withoutModule = withoutGenericArguments.split(separator: ".").last ?? withoutGenericArguments
            return withoutModule.isEmpty ? nil : String(withoutModule)
        }
    }
}
