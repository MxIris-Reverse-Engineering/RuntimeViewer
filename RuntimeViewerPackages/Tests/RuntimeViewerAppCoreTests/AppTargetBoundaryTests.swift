import Foundation
import Testing

/// The macOS app target holds no view model (proposal `view-models-to-app-core`): every ViewModel and
/// cell ViewModel is RuntimeViewerAppCore's, where a test can build and drive it; the app keeps the view
/// controllers, coordinators, lifecycle controllers and the views bound to RuntimeViewerAppCore's types.
/// The compiler does not hold the app to this, so this reads the app target's sources —
/// `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/`, comments and strings left out — and reports,
/// file and line,
///
/// - a type declared with a name ending in `ViewModel`, and
/// - a type whose inheritance clause names `ViewModel<…>`, `CellViewModel` or `ViewModelProtocol`.
///
/// A generic parameter or an associated type named `ViewModel`, as a view controller declares, is no
/// view model and passes.
@Suite("The macOS app target holds no view model")
struct AppTargetBoundaryTests {
    private static let appTargetRelativePath = "RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit"

    private static let appTargetDirectoryURL = PackageSourceScan.repositoryDirectoryURL
        .appendingPathComponent(appTargetRelativePath, isDirectory: true)

    private static let viewModelBaseNames: Set<String> = ["ViewModel", "CellViewModel", "ViewModelProtocol"]

    /// `class`, `struct`, `enum`, `actor`, `protocol` or `typealias`, then the declared name.
    private static let declarationPattern = #"\b(?:class|struct|enum|actor|protocol|typealias)\s+([A-Za-z_][A-Za-z0-9_]*)"#

    /// A type declaration, its generic parameters skipped, then its inheritance clause up to the body or
    /// a `where` clause.
    private static let inheritancePattern = #"\b(?:class|struct|enum|actor)\s+[A-Za-z_][A-Za-z0-9_]*\s*(?:<[^{]*?>)?\s*:\s*([^{]*)"#

    @Test("the app target's sources are where the scan reads them")
    func appTargetDirectoryExists() throws {
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: Self.appTargetDirectoryURL.path, isDirectory: &isDirectory) && isDirectory.boolValue, "\(Self.appTargetRelativePath) is not where the scan looks; the checks below would pass by reading nothing")
        let sourceFiles = try PackageSourceScan.sourceFiles(inDirectory: Self.appTargetDirectoryURL)
        #expect(sourceFiles.count > 50, "only \(sourceFiles.count) Swift files read from \(Self.appTargetRelativePath)")
    }

    @Test("no type in the app target is named as a view model")
    func appTargetDeclaresNoViewModel() throws {
        let declarationRegex = try Regex(Self.declarationPattern)
        var findings: [String] = []
        for sourceFile in try PackageSourceScan.sourceFiles(inDirectory: Self.appTargetDirectoryURL) {
            for line in sourceFile.lines {
                for match in line.code.matches(of: declarationRegex) {
                    guard let nameRange = match.output[1].range else { continue }
                    let name = String(line.code[nameRange])
                    if name.hasSuffix("ViewModel") {
                        findings.append("\(sourceFile.relativePath):\(line.number) declares \(name)")
                    }
                }
            }
        }
        #expect(findings.isEmpty, "view models go in RuntimeViewerAppCore (RuntimeViewerPackages/Sources/AGENTS.md):\n\(findings.joined(separator: "\n"))")
    }

    @Test("no type in the app target inherits a view model base")
    func appTargetInheritsNoViewModel() throws {
        let inheritanceRegex = try Regex(Self.inheritancePattern)
        var findings: [String] = []
        for sourceFile in try PackageSourceScan.sourceFiles(inDirectory: Self.appTargetDirectoryURL) {
            for line in sourceFile.lines {
                guard let match = line.code.firstMatch(of: inheritanceRegex),
                      let clauseRange = match.output[1].range
                else { continue }
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
