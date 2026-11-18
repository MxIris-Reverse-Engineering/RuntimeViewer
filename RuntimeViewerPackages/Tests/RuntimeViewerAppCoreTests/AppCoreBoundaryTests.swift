import Foundation
import Testing

/// RuntimeViewerAppCore can be built and driven in a unit test, no UI component appears in it, and it
/// depends on no UI library (`RuntimeViewerPackages/Sources/AGENTS.md`; proposal
/// `app-core-ui-split`). The rule held in writing alone before, and the adapters that had to be
/// split out of it got in all the same; this reads its sources the way a build does
/// (`PackageSourceScan`: comments and strings left out, every `#if` evaluated for macOS and for the iOS
/// family) and reports, file and line, any of
///
/// 1. an import of a UI library;
/// 2. a type that inherits from a UI component — `NSResponder`, `UIResponder`, a CocoaCoordinator or
///    XCoordinator coordinator base class, or an `NS` / `UI` class whose name ends as a component's
///    does — or conforms to an `NS` / `UI` delegate or data source protocol;
/// 3. a UI component made: one of those classes' initializers called;
/// 4. an import of AppKit, UIKit or Cocoa themselves;
/// 5. any other `NS` / `UI` name than Foundation's (`AppCoreBoundary.allowedSystemPrefixedNames`): an
///    AppKit or UIKit type, or a model Foundation declares for them, such as `NSAttributedString`.
///
/// Rules 4 and 5 come from proposal `app-core-without-ui-models`: RuntimeViewerAppCore describes images,
/// colours, row text and the content pane's text as values, and RuntimeViewerAppUI turns them into
/// AppKit and UIKit objects. They land in steps; until the last one, the files still to be cleaned up
/// are listed in `AppCoreBoundary.filesPendingCleanup` and only rules 1 to 3 apply to them.
///
/// The check reads names, not types: it cannot follow a superclass chain or a type alias. A line it
/// reports that is inside the boundary all the same goes in `allowedLines`, with the reason.
@Suite("RuntimeViewerAppCore stays free of UI components")
struct AppCoreBoundaryTests {
    @Test("RuntimeViewerAppCore imports no UI library and makes, subclasses or serves no UI component")
    func sourcesStayInsideTheBoundary() throws {
        let packageScan = try Self.packageScan.get()
        var findings: [String] = []
        for sourceFile in packageScan.sourceFiles(inTargetNamed: "RuntimeViewerAppCore") {
            let isPendingCleanup = AppCoreBoundary.filesPendingCleanup[sourceFile.relativePath] != nil
            for declaration in AppCoreBoundary.declarations(in: sourceFile) {
                let reasons = isPendingCleanup
                    ? AppCoreBoundary.componentViolations(in: declaration.code)
                    : AppCoreBoundary.violations(in: declaration.code)
                for reason in reasons where !Self.isAllowed(relativePath: sourceFile.relativePath, code: declaration.code) {
                    findings.append("\(sourceFile.relativePath):\(declaration.lineNumber) \(reason)")
                }
            }
        }
        #expect(
            findings.isEmpty,
            "RuntimeViewerAppCore holds no UI component and no AppKit or UIKit type (Sources/AGENTS.md); describe these as values and resolve them in RuntimeViewerAppUI:\n\(findings.joined(separator: "\n"))"
        )
    }

    /// An allowance outlives the line it was written for only by mistake: the next line of that file to
    /// match the piece would pass unchecked.
    @Test("every allowed line still matches a line the rules report")
    func allowedLinesStillMatch() throws {
        let sourceFiles = try Self.packageScan.get().sourceFiles(inTargetNamed: "RuntimeViewerAppCore")
        for allowedLine in Self.allowedLines {
            let sourceFile = try #require(sourceFiles.first { $0.relativePath == allowedLine.relativePath })
            let isStillReported = AppCoreBoundary.declarations(in: sourceFile).contains { declaration in
                declaration.code.contains(allowedLine.code) && !AppCoreBoundary.violations(in: declaration.code).isEmpty
            }
            #expect(isStillReported, "\(allowedLine.relativePath): no reported line contains \"\(allowedLine.code)\" any more; drop the allowance")
        }
    }

    /// The list only shrinks: a file cleaned up, moved or deleted leaves it, so that the rules apply to
    /// it from then on.
    @Test("every file pending cleanup still exists and still names an AppKit or UIKit type")
    func pendingFilesAreStillPending() throws {
        let sourceFiles = try Self.packageScan.get().sourceFiles(inTargetNamed: "RuntimeViewerAppCore")
        for relativePath in AppCoreBoundary.filesPendingCleanup.keys.sorted() {
            let sourceFile = try #require(
                sourceFiles.first { $0.relativePath == relativePath },
                "\(relativePath) is gone; take it off AppCoreBoundary.filesPendingCleanup"
            )
            let isStillPending = AppCoreBoundary.declarations(in: sourceFile).contains { declaration in
                !AppCoreBoundary.platformUIViolations(in: declaration.code).isEmpty
            }
            #expect(isStillPending, "\(relativePath) breaks rules 4 and 5 no more; take it off AppCoreBoundary.filesPendingCleanup")
        }
    }

    @Test("RuntimeViewerAppCore and the package's targets beneath it declare no UI library")
    func manifestDeclaresNoUILibrary() throws {
        let manifest = try Self.packageScan.get().manifest
        var visitedTargetNames: Set<String> = []
        var pendingTargetNames = ["RuntimeViewerAppCore"]
        var findings: [String] = []
        while let targetName = pendingTargetNames.popLast() {
            guard visitedTargetNames.insert(targetName).inserted else { continue }
            let dependencies = try #require(
                ManifestTargetDependencies(ofTargetNamed: targetName, inManifest: manifest),
                "Package.swift declares no target \(targetName)"
            )
            for dependencyName in dependencies.targetNames.union(dependencies.productNames).sorted()
                where AppCoreBoundary.isUILibrary(dependencyName) {
                findings.append("\(targetName) depends on \(dependencyName)")
            }
            pendingTargetNames.append(contentsOf: dependencies.targetNames)
        }
        #expect(findings.isEmpty, "\(findings.joined(separator: "\n"))")
        // The walk went through the targets beneath RuntimeViewerAppCore, not just its own list.
        #expect(visitedTargetNames.isSuperset(of: ["RuntimeViewerAppCore", "RuntimeViewerArchitectures", "RuntimeViewerSettings"]))
    }

    /// Without this the first test would pass by finding nothing to read.
    @Test("the scan reads RuntimeViewerAppCore's sources, and sees the macOS-only ones")
    func scanReadsTheSources() throws {
        let sourceFiles = try Self.packageScan.get().sourceFiles(inTargetNamed: "RuntimeViewerAppCore")
        #expect(sourceFiles.count > 100, "read \(sourceFiles.count) files")
        // `AppRoute.swift` is macOS only, inside `#if os(macOS)`.
        let appRoute = try #require(sourceFiles.first { $0.relativePath == "RuntimeViewerAppCore/AppRoute.swift" })
        #expect(appRoute.lines.contains { $0.code.contains("enum AppRoute") && $0.compilingPlatforms == [.macOS] })
    }

    @Test("each rule reports a line that breaks it", arguments: [
        ("import AppKitPlus", "imports AppKitPlus"),
        ("@_exported import RuntimeViewerUI", "imports RuntimeViewerUI"),
        ("public import RuntimeViewerAppUI", "imports RuntimeViewerAppUI"),
        ("import UIFoundationAppKit", "imports UIFoundationAppKit"),
        ("import struct SwiftUI.Color", "imports SwiftUI"),
        ("import SFSymbols", "imports SFSymbols"),
        ("final class SidebarRowView: NSTableRowView {", "inherits from NSTableRowView"),
        ("open class Responder: NSResponder {", "inherits from NSResponder"),
        ("public final class PageViewController: NSViewController, Sendable {", "inherits from NSViewController"),
        ("final class Flow: ViewCoordinator<FlowRoute, FlowTransition> {", "inherits from ViewCoordinator"),
        ("final class Panel<Content: Hashable>: NSPanel.Window, NSWindowDelegate {", "conforms to NSWindowDelegate"),
        ("extension Model: NSOutlineViewDataSource {", "conforms to NSOutlineViewDataSource"),
        ("extension Model: @MainActor NSFilterTokenFieldDelegate where Self: AnyObject {", "conforms to NSFilterTokenFieldDelegate"),
        ("let menu = NSMenu()", "calls the initializer of NSMenu"),
        ("let popover = NSPopover.init()", "calls the initializer of NSPopover"),
        ("field = NSSearchField(frame: .zero)", "calls the initializer of NSSearchField"),
        ("return NSMenuItem(title: title, action: nil, keyEquivalent: \"\")", "calls the initializer of NSMenuItem"),
        ("let button = UIButton(type: .system)", "calls the initializer of UIButton"),
        ("public class var view: NSView { NSView() }", "calls the initializer of NSView"),
        ("import AppKit", "imports AppKit"),
        ("import UIKit.UIGeometry", "imports UIKit"),
        ("@preconcurrency import Cocoa", "imports Cocoa"),
        ("let image = NSImage(size: NSSize(width: 16, height: 16))", "names NSImage"),
        ("let image = NSImage(size: NSSize(width: 16, height: 16))", "names NSSize"),
        ("let color = NSColor(name: nil) { _ in .black }", "names NSColor"),
        ("let style = NSMutableParagraphStyle()", "names NSMutableParagraphStyle"),
        ("public var title: NSAttributedString = .init()", "names NSAttributedString"),
        ("public var icon: NSUIImage", "names NSUIImage"),
        ("let mask = NSView.AutoresizingMask(rawValue: 0)", "names NSView"),
        ("let identifier = NSUserInterfaceItemIdentifier(\"row\")", "names NSUserInterfaceItemIdentifier"),
        ("var viewController: UIViewController! { nil }", "names UIViewController"),
        ("if let view = object as? NSView {", "names NSView"),
        ("case menu(NSMenu)", "names NSMenu"),
        ("let shade = UIKit.UIColor.systemRed", "names UIKit"),
    ])
    func ruleReportsABreakingLine(code: String, expectedReason: String) {
        #expect(AppCoreBoundary.violations(in: code).contains(expectedReason), "\(AppCoreBoundary.violations(in: code))")
    }

    @Test("a line inside the boundary is not reported", arguments: [
        "import Foundation",
        "import UIFoundationSettings",
        "@_exported import RuntimeViewerArchitectures",
        "final class RuntimeConnectionNotificationService: NSObject, UNUserNotificationCenterDelegate {",
        "final class FindCorpusCoordinator: @unchecked Sendable {",
        "public struct ToolbarState: Hashable {",
        "let kind: RuntimeObjectKind = .objc(.type(.class))",
        "let range = NSRange(location: 0, length: NSNotFound)",
        "guard NSMaxRange(range) <= (text as NSString).length else { return nil }",
        "private let lock = NSLock()",
        "let expression = try NSRegularExpression(pattern: pattern)",
        "let color = Settings.Theme.ColorValue.nsuiColor",
        "let store = UIFoundationSettings.SettingsStore.self",
    ])
    func lineInsideTheBoundaryIsNotReported(code: String) {
        #expect(AppCoreBoundary.violations(in: code).isEmpty, "\(AppCoreBoundary.violations(in: code))")
    }

    @Test("a declaration written over several lines is read whole")
    func declarationOverSeveralLinesIsReadWhole() {
        let sourceFile = ScannedSourceFile(
            relativePath: "Sample.swift",
            source: """
            final class Page:
                NSObject,
                NSTableViewDelegate {
            }
            """,
            macOSOnlyModuleNames: []
        )
        let declarations = AppCoreBoundary.declarations(in: sourceFile)
        #expect(declarations.flatMap { AppCoreBoundary.componentViolations(in: $0.code) } == ["conforms to NSTableViewDelegate"])
    }

    // MARK: - Reading the package

    private static let packageScan = Result { try PackageSourceScan.read(targetNames: ["RuntimeViewerAppCore"]) }

    /// Lines the rules report that are inside the boundary all the same: a file's path and a piece of
    /// the line, with the reason.
    private static let allowedLines: [(relativePath: String, code: String, reason: String)] = [
        (
            "RuntimeViewerAppCore/DocumentState.swift", "import UIKit",
            "XCoordinator's `Presentable` and `TransitionProtocol`, which the private selection router conforms to on iOS, name `UIViewController`"
        ),
        (
            "RuntimeViewerAppCore/DocumentState.swift", "var viewController: UIViewController!",
            "the selection router's `Presentable` requirement; it owns no view controller and returns nil"
        ),
        (
            "RuntimeViewerAppCore/DocumentState.swift", "typealias RootViewController = UIViewController",
            "the empty transition's `TransitionProtocol` requirement"
        ),
        (
            "RuntimeViewerAppCore/DocumentState.swift", "func perform(on rootViewController: UIViewController",
            "the empty transition's `TransitionProtocol` requirement; it does nothing"
        ),
    ]

    private static func isAllowed(relativePath: String, code: String) -> Bool {
        allowedLines.contains { allowedLine in
            allowedLine.relativePath == relativePath && code.contains(allowedLine.code)
        }
    }
}

/// The rules `AppCoreBoundaryTests` applies, line by line.
enum AppCoreBoundary {
    /// The modules RuntimeViewerAppCore may not import: this repository's view libraries and the
    /// application layer above it, and the UI libraries — every module of UIFoundation but
    /// `UIFoundationSettings`, the settings store.
    static func isUILibrary(_ moduleName: String) -> Bool {
        let uiLibraryNames: Set<String> = [
            "RuntimeViewerUI",
            "RuntimeViewerSettingsUI",
            "RuntimeViewerAppUI",
            "RuntimeViewerApplication",
            "SwiftUI",
            "SnapKit",
            "AppKitPlus",
            "SFSymbols",
            "AppKitNavigation",
            "UIKitNavigation",
        ]
        if uiLibraryNames.contains(moduleName) { return true }
        return moduleName.hasPrefix("UIFoundation") && moduleName != "UIFoundationSettings"
    }

    /// CocoaCoordinator's and XCoordinator's coordinator classes: CocoaCoordinator's `Coordinator`
    /// is an `NSResponder`.
    private static let coordinatorClassNames: Set<String> = [
        "Coordinator",
        "AppCoordinator",
        "SceneCoordinator",
        "ViewCoordinator",
        "BaseCoordinator",
        "BasicCoordinator",
        "NavigationCoordinator",
        "PageCoordinator",
        "SplitCoordinator",
        "TabBarCoordinator",
    ]

    /// How the names of AppKit's and UIKit's component classes end. `Bar` takes in `Toolbar`.
    private static let componentNameSuffixes = [
        "View", "ViewController", "Window", "WindowController", "Control", "Cell", "Menu", "MenuItem", "Popover", "Field", "Bar", "Button",
    ]

    /// Whether `typeName` names a UI component: `NSResponder`, `UIResponder`, or an `NS` / `UI` class
    /// whose name ends as a component's does.
    static func isComponentClassName(_ typeName: String) -> Bool {
        if typeName == "NSResponder" || typeName == "UIResponder" { return true }
        return hasSystemPrefix(typeName) && componentNameSuffixes.contains { typeName.hasSuffix($0) }
    }

    /// Whether `typeName` names a delegate or data source protocol of AppKit, UIKit or AppKitPlus.
    static func isComponentProtocolName(_ typeName: String) -> Bool {
        hasSystemPrefix(typeName) && (typeName.hasSuffix("Delegate") || typeName.hasSuffix("DataSource"))
    }

    /// `NS` or `UI`, then a capital: AppKit's, UIKit's and AppKitPlus's spelling.
    private static func hasSystemPrefix(_ typeName: String) -> Bool {
        guard typeName.hasPrefix("NS") || typeName.hasPrefix("UI") else { return false }
        let thirdCharacter = typeName.dropFirst(2).first
        return thirdCharacter?.isUppercase ?? false
    }

    /// Rule 4: the platform's UI frameworks themselves. Their models — images, colours, fonts,
    /// attributed strings, events — are described by values in RuntimeViewerAppCore and resolved in
    /// RuntimeViewerAppUI (proposal `app-core-without-ui-models`).
    static func isPlatformUIFramework(_ moduleName: String) -> Bool {
        ["AppKit", "UIKit", "Cocoa"].contains(moduleName)
    }

    /// Rule 5: the names spelled as AppKit's and UIKit's are that RuntimeViewerAppCore may write all the
    /// same — Foundation's, and the settings store's module. Adding a Foundation name needs no reason;
    /// adding any other does. `NSAttributedString` is left out on purpose: Foundation declares it, but
    /// what it carries is fonts and colours.
    static let allowedSystemPrefixedNames: Set<String> = [
        "NSCharacterSet",
        "NSError",
        "NSLock",
        "NSMakeRange",
        "NSMaxRange",
        "NSNotFound",
        "NSNumber",
        "NSObject",
        "NSObjectProtocol",
        "NSRange",
        "NSRangeException",
        "NSRecursiveLock",
        "NSRegularExpression",
        "NSString",
        "NSURL",
        "UIFoundationSettings",
    ]

    /// The files rules 4 and 5 do not apply to yet, each with the step of proposal
    /// `app-core-without-ui-models` that cleans it up. Empty once the last step lands.
    static let filesPendingCleanup: [String: Int] = [
        "RuntimeViewerAppCore/Content/ContentTextViewModel.swift": 4,
        "RuntimeViewerAppCore/Content/NSAttributedString+ContentLinks.swift": 4,
        "RuntimeViewerAppCore/Extensions.swift": 4,
        "RuntimeViewerAppCore/PlatformTypes.swift": 4,
        "RuntimeViewerAppCore/Theme/FrozenSemanticString+ThemeProfile.swift": 4,
        "RuntimeViewerAppCore/Theme/ThemePreset+ThemeProfile.swift": 4,
        "RuntimeViewerAppCore/Theme/ThemeProfile.swift": 4,
    ]

    /// What `code` breaks, one reason per rule broken.
    static func violations(in code: String) -> [String] {
        componentViolations(in: code) + platformUIViolations(in: code)
    }

    /// What `code` breaks of rules 4 and 5: an import of AppKit, UIKit or Cocoa, and each `NS` / `UI`
    /// name outside `allowedSystemPrefixedNames`, once. An import's module is left to rules 1 and 4.
    static func platformUIViolations(in code: String) -> [String] {
        if let moduleName = SwiftSourceText.importedModuleName(in: code) {
            return isPlatformUIFramework(moduleName) ? ["imports \(moduleName)"] : []
        }
        var reasons: [String] = []
        for name in systemPrefixedNames(in: code) where !allowedSystemPrefixedNames.contains(name) {
            let reason = "names \(name)"
            if !reasons.contains(reason) {
                reasons.append(reason)
            }
        }
        return reasons
    }

    /// The whole identifiers of `code` spelled as AppKit's and UIKit's are, in order: `NS` or `UI`, then
    /// a capital. A member after a `.` is the member's own name, not one of these.
    static func systemPrefixedNames(in code: String) -> [String] {
        let characters = Array(code)
        var names: [String] = []
        var index = 0
        while index < characters.count {
            guard SwiftSourceText.isIdentifierCharacter(characters[index]) else {
                index += 1
                continue
            }
            let isWholeIdentifierStart = index == 0 || characters[index - 1] != "."
            var endIndex = index
            while endIndex < characters.count, SwiftSourceText.isIdentifierCharacter(characters[endIndex]) {
                endIndex += 1
            }
            let identifier = String(characters[index..<endIndex])
            if isWholeIdentifierStart, hasSystemPrefix(identifier) {
                names.append(identifier)
            }
            index = endIndex
        }
        return names
    }

    /// What `code` breaks of rules 1 to 3, one reason per rule broken.
    static func componentViolations(in code: String) -> [String] {
        var reasons: [String] = []
        if let moduleName = SwiftSourceText.importedModuleName(in: code), isUILibrary(moduleName) {
            reasons.append("imports \(moduleName)")
        }
        for inheritedTypeName in inheritedTypeNames(in: code) {
            if isComponentClassName(inheritedTypeName) || coordinatorClassNames.contains(inheritedTypeName) {
                reasons.append("inherits from \(inheritedTypeName)")
            } else if isComponentProtocolName(inheritedTypeName) {
                reasons.append("conforms to \(inheritedTypeName)")
            }
        }
        for constructedTypeName in constructedTypeNames(in: code) where isComponentClassName(constructedTypeName) {
            reasons.append("calls the initializer of \(constructedTypeName)")
        }
        return reasons
    }

    /// The most lines a declaration's header is read over before it is taken as it is.
    private static let maximumHeaderLineCount = 6

    /// A file's compiled lines, each type declaration's header joined into one, so a declaration that
    /// lists what it inherits over several lines is read whole.
    static func declarations(in sourceFile: ScannedSourceFile) -> [(lineNumber: Int, code: String)] {
        var declarations: [(lineNumber: Int, code: String)] = []
        var pendingHeader: (lineNumber: Int, code: String, lineCount: Int)?
        for line in sourceFile.lines where !line.compilingPlatforms.isEmpty {
            if var header = pendingHeader {
                pendingHeader = nil
                if header.lineCount < maximumHeaderLineCount {
                    header.code += " " + line.code.trimmingCharacters(in: .whitespaces)
                    header.lineCount += 1
                    if line.code.contains("{") {
                        declarations.append((header.lineNumber, header.code))
                    } else {
                        pendingHeader = header
                    }
                    continue
                }
                // Too long to be a header; the line is read on its own.
                declarations.append((header.lineNumber, header.code))
            }
            if declaredTypeKeywordRange(in: line.code) != nil, !line.code.contains("{"), line.code.contains(":") || line.code.trimmingCharacters(in: .whitespaces).hasSuffix(",") {
                pendingHeader = (line.number, line.code, 1)
            } else {
                declarations.append((line.number, line.code))
            }
        }
        if let pendingHeader {
            declarations.append((pendingHeader.lineNumber, pendingHeader.code))
        }
        return declarations
    }

    /// Where the keyword of a type declaration or extension sits in `code`, if the line declares one.
    private static func declaredTypeKeywordRange(in code: String) -> Range<String.Index>? {
        for keyword in ["class", "struct", "enum", "actor", "protocol", "extension"] {
            var searchRange = code.startIndex..<code.endIndex
            while let keywordRange = code.range(of: keyword, range: searchRange) {
                let precedingCharacter = keywordRange.lowerBound > code.startIndex ? code[code.index(before: keywordRange.lowerBound)] : nil
                let followingCharacter = keywordRange.upperBound < code.endIndex ? code[keywordRange.upperBound] : nil
                let isWholeWord = !(precedingCharacter.map(SwiftSourceText.isIdentifierCharacter) ?? false)
                    && !(precedingCharacter == ".")
                    && (followingCharacter?.isWhitespace ?? false)
                if isWholeWord {
                    let prefix = code[..<keywordRange.lowerBound].trimmingCharacters(in: .whitespaces)
                    // Only attributes and modifiers may come before the keyword.
                    let prefixWords = prefix.split(whereSeparator: \.isWhitespace)
                    let modifiers: Set<String> = ["public", "package", "internal", "fileprivate", "private", "open", "final", "indirect", "nonisolated", "distributed"]
                    // `class func`, `class var` and the like are members, not types.
                    let nextWord = code[keywordRange.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init)
                    let memberKeywords: Set<String> = ["func", "var", "let", "subscript", "init", "deinit", "case", "override", "final", "static"]
                    if prefixWords.allSatisfy({ $0.hasPrefix("@") || modifiers.contains(String($0)) || $0.hasPrefix("(") || $0.hasSuffix(")") }),
                       !(nextWord.map(memberKeywords.contains) ?? true) {
                        return keywordRange
                    }
                }
                searchRange = keywordRange.upperBound..<code.endIndex
            }
        }
        return nil
    }

    /// The types a declaration on this line inherits from or conforms to: what follows the `:` after
    /// its name and generic parameters, up to `{` or `where`, each without its module, generic arguments
    /// and attributes.
    static func inheritedTypeNames(in code: String) -> [String] {
        guard let keywordRange = declaredTypeKeywordRange(in: code) else { return [] }
        let afterKeyword = code[keywordRange.upperBound...]
        // Past the name and its generic parameters, whose constraints use `:` too.
        var index = afterKeyword.startIndex
        var angleBracketDepth = 0
        var colonIndex: String.Index?
        while index < afterKeyword.endIndex {
            let character = afterKeyword[index]
            if character == "<" {
                angleBracketDepth += 1
            } else if character == ">" {
                angleBracketDepth -= 1
            } else if character == "{" {
                break
            } else if character == ":", angleBracketDepth == 0 {
                colonIndex = index
                break
            }
            index = afterKeyword.index(after: index)
        }
        guard let colonIndex else { return [] }
        var inheritanceClause = String(afterKeyword[afterKeyword.index(after: colonIndex)...])
        if let braceIndex = inheritanceClause.firstIndex(of: "{") {
            inheritanceClause = String(inheritanceClause[..<braceIndex])
        }
        if let whereRange = inheritanceClause.range(of: " where ") {
            inheritanceClause = String(inheritanceClause[..<whereRange.lowerBound])
        }
        return topLevelEntries(of: inheritanceClause).flatMap { entry in
            entry.split(separator: "&").compactMap { typeReference in
                typeName(of: String(typeReference))
            }
        }
    }

    /// The comma-separated entries of an inheritance clause, commas inside generic arguments kept.
    private static func topLevelEntries(of clause: String) -> [String] {
        var entries: [String] = []
        var currentEntry = ""
        var angleBracketDepth = 0
        for character in clause {
            if character == "<" {
                angleBracketDepth += 1
            } else if character == ">" {
                angleBracketDepth -= 1
            }
            if character == ",", angleBracketDepth == 0 {
                entries.append(currentEntry)
                currentEntry = ""
            } else {
                currentEntry.append(character)
            }
        }
        entries.append(currentEntry)
        return entries
    }

    /// `AppKit.NSView`, `@MainActor NSTableViewDelegate`, `ViewCoordinator<Route, Transition>`: the
    /// type's own name.
    private static func typeName(of typeReference: String) -> String? {
        var words = typeReference.split(whereSeparator: \.isWhitespace).map(String.init)
        words.removeAll { $0.hasPrefix("@") || $0 == "~Copyable" || $0 == "~Escapable" }
        guard var reference = words.first else { return nil }
        if let genericArgumentsStart = reference.firstIndex(of: "<") {
            reference = String(reference[..<genericArgumentsStart])
        }
        let name = reference.split(separator: ".").last.map(String.init) ?? reference
        return name.isEmpty ? nil : name
    }

    /// The types `code` calls an initializer of: a type name followed by `(` or by `.init(`.
    static func constructedTypeNames(in code: String) -> [String] {
        let characters = Array(code)
        var typeNames: [String] = []
        var index = 0
        while index < characters.count {
            guard characters[index].isUppercase,
                  index == 0 || !(SwiftSourceText.isIdentifierCharacter(characters[index - 1]) || characters[index - 1] == ".")
            else {
                index += 1
                continue
            }
            var endIndex = index
            while endIndex < characters.count, SwiftSourceText.isIdentifierCharacter(characters[endIndex]) {
                endIndex += 1
            }
            let identifier = String(characters[index..<endIndex])
            let remainder = String(characters[endIndex...])
            if remainder.hasPrefix("(") || remainder.hasPrefix(".init(") {
                typeNames.append(identifier)
            }
            index = endIndex
        }
        return typeNames
    }
}
