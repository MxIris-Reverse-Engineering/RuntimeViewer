import Foundation
import Testing

/// The iOS, visionOS and jailbroken iOS apps compile these four targets too,
/// and only the release job builds those apps — so code that compiles on
/// macOS alone has, more than once, been found by a failed release rather
/// than by a test. A macOS test run cannot compile for iOS, so this reads the
/// sources the way an iOS-family build does: every `#if` is evaluated for iOS
/// and for visionOS, and whatever either of them would compile is checked for
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
        var findings: [String] = []
        for sourceFile in packageScan.sourceFiles(inTargetNamed: targetName) {
            for line in sourceFile.lines where line.isCompiledForIOSFamily {
                if let moduleName = Self.importedModuleName(in: line.code),
                   packageScan.macOSOnlyModuleNames.contains(moduleName) {
                    findings.append("\(sourceFile.relativePath):\(line.number) imports \(moduleName)")
                }
                for dependencyKeyName in packageScan.macOSOnlyDependencyKeyNames.sorted()
                    where Self.code(line.code, containsWord: dependencyKeyName) {
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
        #expect(packageScan.macOSOnlyDependencyKeyNames.contains("appRouter"))
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
        let isCompiled = IOSFamilyPlatform.allCases.contains { platform in
            parsedCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .unsatisfied
        }
        #expect(isCompiled == isCompiledForIOSFamily)
    }

    // MARK: - Reading the package

    private static let packageScan = Result { try PackageScan.make() }

    private struct PackageScan {
        let macOSOnlyModuleNames: Set<String>
        let macOSOnlyDependencyKeyNames: Set<String>
        let sourceFilesByTargetName: [String: [SourceFile]]

        func sourceFiles(inTargetNamed targetName: String) -> [SourceFile] {
            sourceFilesByTargetName[targetName] ?? []
        }

        static func make() throws -> PackageScan {
            let packageDirectoryURL = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent() // RuntimeViewerApplicationTests
                .deletingLastPathComponent() // Tests
                .deletingLastPathComponent() // RuntimeViewerPackages
            let manifest = try String(contentsOf: packageDirectoryURL.appendingPathComponent("Package.swift"), encoding: .utf8)
            let macOSOnlyModuleNames = macOSOnlyModuleNames(inManifest: manifest).union(["AppKit", "Cocoa"])

            var sourceFilesByTargetName: [String: [SourceFile]] = [:]
            for targetName in crossPlatformTargetNames {
                let targetDirectoryURL = packageDirectoryURL.appendingPathComponent("Sources/\(targetName)", isDirectory: true)
                guard let enumerator = FileManager.default.enumerator(at: targetDirectoryURL, includingPropertiesForKeys: nil) else {
                    continue
                }
                for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                    let source = try String(contentsOf: fileURL, encoding: .utf8)
                    let relativePath = targetName + fileURL.path.dropFirst(targetDirectoryURL.path.count)
                    sourceFilesByTargetName[targetName, default: []].append(
                        SourceFile(relativePath: relativePath, source: source, macOSOnlyModuleNames: macOSOnlyModuleNames)
                    )
                }
            }

            // A key declared on macOS only, and nowhere an iOS-family build
            // compiles, is one no iOS-family code may name.
            var dependencyKeyNamesCompiledForIOSFamily: Set<String> = []
            var dependencyKeyNamesCompiledForMacOSOnly: Set<String> = []
            for sourceFile in sourceFilesByTargetName.values.joined() {
                for declaration in sourceFile.dependencyKeyDeclarations {
                    if declaration.isCompiledForIOSFamily {
                        dependencyKeyNamesCompiledForIOSFamily.insert(declaration.name)
                    } else {
                        dependencyKeyNamesCompiledForMacOSOnly.insert(declaration.name)
                    }
                }
            }

            return PackageScan(
                macOSOnlyModuleNames: macOSOnlyModuleNames,
                macOSOnlyDependencyKeyNames: dependencyKeyNamesCompiledForMacOSOnly.subtracting(dependencyKeyNamesCompiledForIOSFamily),
                sourceFilesByTargetName: sourceFilesByTargetName
            )
        }

        /// Every product or target the manifest depends on under
        /// `.when(platforms: appkitPlatforms)`, one dependency per line.
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

    private struct SourceLine {
        let number: Int
        /// The line with its comments and string contents blanked out.
        let code: String
        let isCompiledForIOSFamily: Bool
    }

    private struct DependencyKeyDeclaration {
        let name: String
        let isCompiledForIOSFamily: Bool
    }

    private struct SourceFile {
        let relativePath: String
        let lines: [SourceLine]

        init(relativePath: String, source: String, macOSOnlyModuleNames: Set<String>) {
            self.relativePath = relativePath
            // One entry per `#if` the line sits in: the conditions of the
            // branches before the one in force, and that branch's own — `nil`
            // for `#else`.
            var openConditionalBlocks: [(earlierBranchConditions: [CompilationCondition], currentBranchCondition: CompilationCondition?)] = []
            var lines: [SourceLine] = []
            for (lineIndex, code) in CrossPlatformSourceGuardTests.codeOnlyLines(of: source).enumerated() {
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
                    let isCompiledForIOSFamily = IOSFamilyPlatform.allCases.contains { platform in
                        openConditionalBlocks.allSatisfy { conditionalBlock in
                            let noEarlierBranchIsTaken = conditionalBlock.earlierBranchConditions.allSatisfy { earlierCondition in
                                earlierCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .satisfied
                            }
                            let currentBranchCanBeTaken = conditionalBlock.currentBranchCondition.map { currentCondition in
                                currentCondition.value(for: platform, macOSOnlyModuleNames: macOSOnlyModuleNames) != .unsatisfied
                            } ?? true
                            return noEarlierBranchIsTaken && currentBranchCanBeTaken
                        }
                    }
                    lines.append(SourceLine(number: lineIndex + 1, code: code, isCompiledForIOSFamily: isCompiledForIOSFamily))
                }
            }
            self.lines = lines
        }

        /// The `var` each `@DependencyEntry` attribute declares, looked for on
        /// the attribute's own line and the few after it.
        var dependencyKeyDeclarations: [DependencyKeyDeclaration] {
            var declarations: [DependencyKeyDeclaration] = []
            for (lineIndex, line) in lines.enumerated() where line.code.contains("@DependencyEntry") {
                for candidateLine in lines[lineIndex..<min(lineIndex + 4, lines.count)] {
                    guard let name = Self.declaredVariableName(in: candidateLine.code) else { continue }
                    declarations.append(DependencyKeyDeclaration(name: name, isCompiledForIOSFamily: candidateLine.isCompiledForIOSFamily))
                    break
                }
            }
            return declarations
        }

        /// What follows `directive` on a line that is that directive; `nil`
        /// on any other line. `#else` does not match `#elseif`.
        private static func directiveArgument(in trimmedCode: String, directive: String) -> String? {
            guard trimmedCode.hasPrefix(directive) else { return nil }
            let remainder = trimmedCode.dropFirst(directive.count)
            guard let firstCharacter = remainder.first else { return "" }
            guard firstCharacter.isWhitespace || firstCharacter == "(" || firstCharacter == "!" else { return nil }
            return remainder.trimmingCharacters(in: .whitespaces)
        }

        private static func declaredVariableName(in code: String) -> String? {
            let words = code.split(whereSeparator: { character in character.isWhitespace || character == ":" })
            guard let variableKeywordIndex = words.firstIndex(of: "var"), variableKeywordIndex + 1 < words.count else { return nil }
            return String(words[variableKeywordIndex + 1])
        }
    }

    // MARK: - Reading a line

    /// The module a line imports, if it is an import declaration.
    private static func importedModuleName(in code: String) -> String? {
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
    private static func code(_ code: String, containsWord word: String) -> Bool {
        func isIdentifierCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "_"
        }
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

    /// `source` line for line, with every comment and the contents of every
    /// string literal replaced by spaces, so a word in either is not taken for
    /// code and a `#if` inside a comment is not taken for a directive.
    private static func codeOnlyLines(of source: String) -> [String] {
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

/// The platforms whose apps compile the cross-platform targets besides macOS.
/// The jailbroken iOS app is iOS as far as conditions go.
private enum IOSFamilyPlatform: CaseIterable {
    case iOS
    case visionOS
}

/// What a condition comes to on a platform, when the platform alone decides
/// it; `undetermined` when something else does — a build flag, the
/// architecture, a module that may or may not be there.
private enum ConditionValue {
    case satisfied
    case unsatisfied
    case undetermined
}

/// A `#if` / `#elseif` condition: `!`, `&&`, `||`, parentheses, and the
/// platform checks and flags they combine.
private indirect enum CompilationCondition {
    case literal(Bool)
    case flag(String)
    case platformCheck(function: String, argument: String)
    case negation(CompilationCondition)
    case conjunction(CompilationCondition, CompilationCondition)
    case disjunction(CompilationCondition, CompilationCondition)
    /// Read as undetermined, so a condition this parser does not understand
    /// leaves its code checked rather than skipped.
    case unparseable

    static func parse(_ text: String) -> CompilationCondition {
        var parser = Parser(characters: Array(text))
        return parser.parse()
    }

    func value(for platform: IOSFamilyPlatform, macOSOnlyModuleNames: Set<String>) -> ConditionValue {
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
        for platform: IOSFamilyPlatform,
        macOSOnlyModuleNames: Set<String>
    ) -> ConditionValue {
        switch function {
        case "os":
            switch argument {
            case "iOS":
                return platform == .iOS ? .satisfied : .unsatisfied
            case "visionOS", "xrOS":
                return platform == .visionOS ? .satisfied : .unsatisfied
            case "macOS", "OSX", "tvOS", "watchOS", "Linux", "Windows", "Android", "FreeBSD", "OpenBSD", "WASI":
                return .unsatisfied
            default:
                return .undetermined
            }
        case "canImport":
            let moduleName = argument.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? argument
            if macOSOnlyModuleNames.contains(moduleName) { return .unsatisfied }
            if moduleName == "UIKit" { return .satisfied }
            return .undetermined
        case "targetEnvironment":
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
