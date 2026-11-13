import Foundation

/// RuntimeViewerPackages' manifest and the Swift sources of some of its targets, read as text, for the
/// tests that check what a target's code may contain: `CrossPlatformSourceGuardTests` (nothing an
/// iOS-family build compiles is macOS-only) and `AppCoreBoundaryTests` (no UI component in
/// RuntimeViewerAppCore). A macOS test run cannot compile for another platform, so a line is kept with
/// its comments and string contents blanked out and with the platforms whose builds may compile it:
/// every `#if` around it is evaluated for macOS and for the iOS family.
struct PackageSourceScan {
    /// The manifest, as text.
    let manifest: String

    /// Every product or target the manifest depends on under `.when(platforms: appkitPlatforms)`,
    /// plus AppKit and Cocoa.
    let macOSOnlyModuleNames: Set<String>

    private let sourceFilesByTargetName: [String: [ScannedSourceFile]]

    func sourceFiles(inTargetNamed targetName: String) -> [ScannedSourceFile] {
        sourceFilesByTargetName[targetName] ?? []
    }

    /// Reads the manifest, and the Swift files under `Sources/<target>` of each of `targetNames`.
    static func read(targetNames: [String]) throws -> PackageSourceScan {
        let manifest = try String(contentsOf: packageDirectoryURL.appendingPathComponent("Package.swift"), encoding: .utf8)
        let macOSOnlyModuleNames = macOSOnlyModuleNames(inManifest: manifest).union(["AppKit", "Cocoa"])

        var sourceFilesByTargetName: [String: [ScannedSourceFile]] = [:]
        for targetName in targetNames {
            let targetDirectoryURL = packageDirectoryURL.appendingPathComponent("Sources/\(targetName)", isDirectory: true)
            guard let enumerator = FileManager.default.enumerator(at: targetDirectoryURL, includingPropertiesForKeys: nil) else {
                continue
            }
            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let source = try String(contentsOf: fileURL, encoding: .utf8)
                let relativePath = targetName + fileURL.path.dropFirst(targetDirectoryURL.path.count)
                sourceFilesByTargetName[targetName, default: []].append(
                    ScannedSourceFile(relativePath: relativePath, source: source, macOSOnlyModuleNames: macOSOnlyModuleNames)
                )
            }
        }
        return PackageSourceScan(manifest: manifest, macOSOnlyModuleNames: macOSOnlyModuleNames, sourceFilesByTargetName: sourceFilesByTargetName)
    }

    /// `RuntimeViewerPackages/`, found from this file's own path.
    private static var packageDirectoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // RuntimeViewerAppCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // RuntimeViewerPackages
    }

    /// Every product or target the manifest depends on under `.when(platforms: appkitPlatforms)`,
    /// one dependency per line.
    private static func macOSOnlyModuleNames(inManifest manifest: String) -> Set<String> {
        var moduleNames: Set<String> = []
        for line in manifest.components(separatedBy: .newlines) where line.contains("condition: .when(platforms: appkitPlatforms)") {
            guard let nameRange = line.range(of: "name: \"") else { continue }
            let remainder = line[nameRange.upperBound...]
            guard let closingQuoteIndex = remainder.firstIndex(of: "\"") else { continue }
            moduleNames.insert(String(remainder[..<closingQuoteIndex]))
        }
        return moduleNames
    }
}

// MARK: - The package's targets in the manifest

/// What the manifest declares a target to depend on: the targets of this package, and the products of
/// other packages, by name. Read from the target's `dependencies:` list as text, which the manifest writes
/// one dependency per line.
struct ManifestTargetDependencies: Equatable {
    var targetNames: Set<String> = []
    var productNames: Set<String> = []

    /// The dependencies of the target named `targetName` in `manifest`, or `nil` when the manifest
    /// declares no such target.
    init?(ofTargetNamed targetName: String, inManifest manifest: String) {
        let lines = manifest.components(separatedBy: .newlines)
        // A product of the same name is declared the same way, under `.library(`.
        guard let nameLineIndex = lines.indices.first(where: { lineIndex in
            lineIndex > 0
                && lines[lineIndex].trimmingCharacters(in: .whitespaces) == "name: \"\(targetName)\","
                && (lines[lineIndex - 1].contains(".target(") || lines[lineIndex - 1].contains(".testTarget("))
        }) else { return nil }
        var isInDependencies = false
        for line in lines[(nameLineIndex + 1)...] {
            let trimmedLine = line.trimmingCharacters(in: .whitespaces)
            if !isInDependencies {
                if trimmedLine.hasPrefix("dependencies: [") {
                    isInDependencies = true
                } else if trimmedLine.hasPrefix("),") || trimmedLine == ")" {
                    break
                }
                continue
            }
            if trimmedLine.hasPrefix("],") || trimmedLine == "]" {
                break
            }
            if trimmedLine.hasPrefix(".product(") {
                if let productName = Self.quotedValue(after: "name: \"", in: trimmedLine) {
                    productNames.insert(productName)
                }
            } else if trimmedLine.hasPrefix(".target(") {
                if let dependencyTargetName = Self.quotedValue(after: "name: \"", in: trimmedLine) {
                    targetNames.insert(dependencyTargetName)
                }
            } else if trimmedLine.hasPrefix("\""), let dependencyTargetName = Self.quotedValue(after: "\"", in: trimmedLine) {
                targetNames.insert(dependencyTargetName)
            }
        }
    }

    private static func quotedValue(after prefix: String, in line: String) -> String? {
        guard let prefixRange = line.range(of: prefix) else { return nil }
        let remainder = line[prefixRange.upperBound...]
        guard let closingQuoteIndex = remainder.firstIndex(of: "\"") else { return nil }
        return String(remainder[..<closingQuoteIndex])
    }
}

// MARK: - Sources

/// The platforms whose builds compile the package's targets: macOS, and the iOS family — the iOS,
/// visionOS and jailbroken iOS apps, the last iOS as far as conditions go.
enum ScannedPlatform: CaseIterable {
    case macOS
    case iOS
    case visionOS

    static let iOSFamily: Set<ScannedPlatform> = [.iOS, .visionOS]
}

struct ScannedSourceLine {
    let number: Int

    /// The line with its comments and string contents blanked out.
    let code: String

    /// The platforms whose builds may compile the line: those for which no `#if` around it is known to
    /// be false.
    let compilingPlatforms: Set<ScannedPlatform>

    var isCompiledForIOSFamily: Bool {
        !compilingPlatforms.isDisjoint(with: ScannedPlatform.iOSFamily)
    }
}

struct ScannedSourceFile {
    let relativePath: String
    let lines: [ScannedSourceLine]

    init(relativePath: String, source: String, macOSOnlyModuleNames: Set<String>) {
        self.relativePath = relativePath
        // One entry per `#if` the line sits in: the conditions of the branches before the one in
        // force, and that branch's own — `nil` for `#else`.
        var openConditionalBlocks: [(earlierBranchConditions: [CompilationCondition], currentBranchCondition: CompilationCondition?)] = []
        var lines: [ScannedSourceLine] = []
        for (lineIndex, code) in SwiftSourceText.codeOnlyLines(of: source).enumerated() {
            let trimmedCode = code.trimmingCharacters(in: .whitespaces)
            if let conditionText = Self.directiveArgument(in: trimmedCode, directive: "#if") {
                openConditionalBlocks.append(([], CompilationCondition.parse(conditionText)))
            } else if let conditionText = Self.directiveArgument(in: trimmedCode, directive: "#elseif"), !openConditionalBlocks.isEmpty {
                let lastIndex = openConditionalBlocks.count - 1
                if let currentBranchCondition = openConditionalBlocks[lastIndex].currentBranchCondition {
                    openConditionalBlocks[lastIndex].earlierBranchConditions.append(currentBranchCondition)
                }
                openConditionalBlocks[lastIndex].currentBranchCondition = CompilationCondition.parse(conditionText)
            } else if Self.directiveArgument(in: trimmedCode, directive: "#else") != nil, !openConditionalBlocks.isEmpty {
                let lastIndex = openConditionalBlocks.count - 1
                if let currentBranchCondition = openConditionalBlocks[lastIndex].currentBranchCondition {
                    openConditionalBlocks[lastIndex].earlierBranchConditions.append(currentBranchCondition)
                }
                openConditionalBlocks[lastIndex].currentBranchCondition = nil
            } else if Self.directiveArgument(in: trimmedCode, directive: "#endif") != nil, !openConditionalBlocks.isEmpty {
                openConditionalBlocks.removeLast()
            } else {
                let compilingPlatforms = Set(ScannedPlatform.allCases.filter { platform in
                    openConditionalBlocks.allSatisfy { conditionalBlock in
                        let noEarlierBranchIsTaken = conditionalBlock.earlierBranchConditions.allSatisfy { earlierCondition in
                            earlierCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .satisfied
                        }
                        let currentBranchCanBeTaken = conditionalBlock.currentBranchCondition.map { currentCondition in
                            currentCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .unsatisfied
                        } ?? true
                        return noEarlierBranchIsTaken && currentBranchCanBeTaken
                    }
                })
                lines.append(ScannedSourceLine(number: lineIndex + 1, code: code, compilingPlatforms: compilingPlatforms))
            }
        }
        self.lines = lines
    }

    /// What follows `directive` on a line that is that directive; `nil` on any other line. `#else`
    /// does not match `#elseif`.
    private static func directiveArgument(in trimmedCode: String, directive: String) -> String? {
        guard trimmedCode.hasPrefix(directive) else { return nil }
        let remainder = trimmedCode.dropFirst(directive.count)
        guard let firstCharacter = remainder.first else { return "" }
        guard firstCharacter.isWhitespace || firstCharacter == "(" || firstCharacter == "!" else { return nil }
        return remainder.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Reading a line

enum SwiftSourceText {
    /// The module a line imports, if it is an import declaration.
    static func importedModuleName(in code: String) -> String? {
        let accessModifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private", "open"]
        let importKinds: Set<String> = ["typealias", "struct", "class", "enum", "protocol", "let", "var", "func"]
        var words = code.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        while let firstWord = words.first, firstWord.hasPrefix("@") || accessModifiers.contains(firstWord) {
            words = words.dropFirst()
        }
        guard words.first == "import" else { return nil }
        words = words.dropFirst()
        if let firstWord = words.first, importKinds.contains(firstWord) {
            words = words.dropFirst()
        }
        return words.first?.split(separator: ".").first.map(String.init)
    }

    /// Whether `word` appears in `code` as a whole identifier.
    static func code(_ code: String, containsWord word: String) -> Bool {
        var searchRange = code.startIndex..<code.endIndex
        while let foundRange = code.range(of: word, range: searchRange) {
            let precedingCharacter = foundRange.lowerBound > code.startIndex ? code[code.index(before: foundRange.lowerBound)] : nil
            let followingCharacter = foundRange.upperBound < code.endIndex ? code[foundRange.upperBound] : nil
            if !(precedingCharacter.map(isIdentifierCharacter) ?? false), !(followingCharacter.map(isIdentifierCharacter) ?? false) {
                return true
            }
            searchRange = foundRange.upperBound..<code.endIndex
        }
        return false
    }

    static func isIdentifierCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// `source` line for line, with every comment and the contents of every string literal replaced
    /// by spaces, so a word in either is not taken for code and a `#if` inside a comment is not taken
    /// for a directive.
    static func codeOnlyLines(of source: String) -> [String] {
        let characters = Array(source)
        var codeLines: [String] = []
        var currentLine = ""
        var blockCommentDepth = 0
        var isInStringLiteral = false
        var isInMultilineStringLiteral = false
        var index = 0

        func startsTripleQuote(at position: Int) -> Bool {
            position + 2 < characters.count && characters[position] == "\"" && characters[position + 1] == "\"" && characters[position + 2] == "\""
        }

        while index < characters.count {
            let character = characters[index]
            let nextCharacter: Character? = index + 1 < characters.count ? characters[index + 1] : nil
            if character.isNewline {
                codeLines.append(currentLine)
                currentLine = ""
                // A single-line string literal cannot run past its line.
                isInStringLiteral = false
                index += 1
            } else if blockCommentDepth > 0 {
                if character == "*", nextCharacter == "/" {
                    blockCommentDepth -= 1
                    currentLine += "  "
                    index += 2
                } else if character == "/", nextCharacter == "*" {
                    blockCommentDepth += 1
                    currentLine += "  "
                    index += 2
                } else {
                    currentLine += " "
                    index += 1
                }
            } else if isInMultilineStringLiteral {
                if startsTripleQuote(at: index) {
                    isInMultilineStringLiteral = false
                    currentLine += "\"\"\""
                    index += 3
                } else if character == "\\", let nextCharacter, !nextCharacter.isNewline {
                    currentLine += "  "
                    index += 2
                } else {
                    currentLine += " "
                    index += 1
                }
            } else if isInStringLiteral {
                if character == "\\", let nextCharacter, !nextCharacter.isNewline {
                    currentLine += "  "
                    index += 2
                } else if character == "\"" {
                    isInStringLiteral = false
                    currentLine += "\""
                    index += 1
                } else {
                    currentLine += " "
                    index += 1
                }
            } else if character == "/", nextCharacter == "/" {
                while index < characters.count, !characters[index].isNewline {
                    currentLine += " "
                    index += 1
                }
            } else if character == "/", nextCharacter == "*" {
                blockCommentDepth = 1
                currentLine += "  "
                index += 2
            } else if startsTripleQuote(at: index) {
                isInMultilineStringLiteral = true
                currentLine += "\"\"\""
                index += 3
            } else if character == "\"" {
                isInStringLiteral = true
                currentLine += "\""
                index += 1
            } else {
                currentLine.append(character)
                index += 1
            }
        }
        codeLines.append(currentLine)
        return codeLines
    }
}

// MARK: - Compilation conditions

/// What a condition comes to on a platform, when the platform alone decides it; `undetermined` when
/// something else does — a build flag, the architecture, a module that may or may not be there.
enum ConditionValue {
    case satisfied
    case unsatisfied
    case undetermined
}

/// A `#if` / `#elseif` condition: `!`, `&&`, `||`, parentheses, and the platform checks and flags they
/// combine.
indirect enum CompilationCondition {
    case literal(Bool)
    case flag(String)
    case platformCheck(function: String, argument: String)
    case negation(CompilationCondition)
    case conjunction(CompilationCondition, CompilationCondition)
    case disjunction(CompilationCondition, CompilationCondition)
    /// Read as undetermined, so a condition this parser does not understand leaves its code checked
    /// rather than skipped.
    case unparseable

    static func parse(_ text: String) -> CompilationCondition {
        var parser = Parser(characters: Array(text))
        return parser.parse()
    }

    func value(for platform: ScannedPlatform, macOSOnlyModuleNames: Set<String>) -> ConditionValue {
        switch self {
        case .literal(let isSatisfied):
            return isSatisfied ? .satisfied : .unsatisfied
        case .flag, .unparseable:
            return .undetermined
        case .platformCheck(let function, let argument):
            return Self.value(ofPlatformCheck: function, argument: argument, for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames)
        case .negation(let operand):
            switch operand.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) {
            case .satisfied: return .unsatisfied
            case .unsatisfied: return .satisfied
            case .undetermined: return .undetermined
            }
        case .conjunction(let leftOperand, let rightOperand):
            let leftValue = leftOperand.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames)
            let rightValue = rightOperand.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames)
            if leftValue == .unsatisfied || rightValue == .unsatisfied { return .unsatisfied }
            if leftValue == .satisfied, rightValue == .satisfied { return .satisfied }
            return .undetermined
        case .disjunction(let leftOperand, let rightOperand):
            let leftValue = leftOperand.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames)
            let rightValue = rightOperand.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames)
            if leftValue == .satisfied || rightValue == .satisfied { return .satisfied }
            if leftValue == .unsatisfied, rightValue == .unsatisfied { return .unsatisfied }
            return .undetermined
        }
    }

    private static func value(
        ofPlatformCheck function: String,
        argument: String,
        for platform: ScannedPlatform,
        macOSOnlyModuleNames: Set<String>
    ) -> ConditionValue {
        switch function {
        case "os":
            switch argument {
            case "macOS", "OSX":
                return platform == .macOS ? .satisfied : .unsatisfied
            case "iOS":
                return platform == .iOS ? .satisfied : .unsatisfied
            case "visionOS", "xrOS":
                return platform == .visionOS ? .satisfied : .unsatisfied
            case "tvOS", "watchOS", "Linux", "Windows", "Android", "FreeBSD", "OpenBSD", "WASI":
                return .unsatisfied
            default:
                return .undetermined
            }
        case "canImport":
            let moduleName = argument.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? argument
            switch platform {
            case .macOS:
                if moduleName == "AppKit" || moduleName == "Cocoa" { return .satisfied }
                if moduleName == "UIKit" { return .unsatisfied }
                return .undetermined
            case .iOS, .visionOS:
                if macOSOnlyModuleNames.contains(moduleName) { return .unsatisfied }
                if moduleName == "UIKit" { return .satisfied }
                return .undetermined
            }
        case "targetEnvironment":
            // Neither a native macOS build nor an iOS-family one is Mac Catalyst.
            return argument == "macCatalyst" ? .unsatisfied : .undetermined
        default:
            return .undetermined
        }
    }

    private struct Parser {
        let characters: [Character]
        var position = 0

        mutating func parse() -> CompilationCondition {
            let condition = parseDisjunction()
            skipWhitespace()
            return position == characters.count ? condition : .unparseable
        }

        private mutating func parseDisjunction() -> CompilationCondition {
            var condition = parseConjunction()
            while consume("||") {
                condition = .disjunction(condition, parseConjunction())
            }
            return condition
        }

        private mutating func parseConjunction() -> CompilationCondition {
            var condition = parseNegation()
            while consume("&&") {
                condition = .conjunction(condition, parseNegation())
            }
            return condition
        }

        private mutating func parseNegation() -> CompilationCondition {
            consume("!") ? .negation(parseNegation()) : parseOperand()
        }

        private mutating func parseOperand() -> CompilationCondition {
            if consume("(") {
                let condition = parseDisjunction()
                return consume(")") ? condition : .unparseable
            }
            skipWhitespace()
            var identifier = ""
            while position < characters.count, characters[position].isLetter || characters[position].isNumber || characters[position] == "_" {
                identifier.append(characters[position])
                position += 1
            }
            guard !identifier.isEmpty else { return .unparseable }
            skipWhitespace()
            guard position < characters.count, characters[position] == "(" else {
                switch identifier {
                case "true": return .literal(true)
                case "false": return .literal(false)
                default: return .flag(identifier)
                }
            }
            position += 1
            var nestingDepth = 1
            var argument = ""
            while position < characters.count {
                let character = characters[position]
                position += 1
                if character == "(" {
                    nestingDepth += 1
                } else if character == ")" {
                    nestingDepth -= 1
                    if nestingDepth == 0 { break }
                }
                argument.append(character)
            }
            guard nestingDepth == 0 else { return .unparseable }
            return .platformCheck(function: identifier, argument: argument.trimmingCharacters(in: .whitespaces))
        }

        private mutating func consume(_ token: String) -> Bool {
            skipWhitespace()
            let tokenCharacters = Array(token)
            guard position + tokenCharacters.count <= characters.count,
                  Array(characters[position..<(position + tokenCharacters.count)]) == tokenCharacters
            else { return false }
            position += tokenCharacters.count
            return true
        }

        private mutating func skipWhitespace() {
            while position < characters.count, characters[position].isWhitespace {
                position += 1
            }
        }
    }
}
