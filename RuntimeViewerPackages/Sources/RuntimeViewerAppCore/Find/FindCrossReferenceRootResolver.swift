import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// The roots a term typed into the query field gives a cross-reference
/// search: every method, property or function it matches for Call Hierarchy
/// and Callees, every class, struct or enum for Type References.
///
/// Xcode matches a plain name under the match style and Match Case, and a
/// name qualified by its type — `-[NSWindow makeKeyAndOrderFront:]`,
/// `NSWindow.title` — by the member's name and then the type's exactly, the
/// match style and the case aside
/// (`-[IDEBatchFindQuerySpecification termSymbolsForWorkspace:useQualifiedNameParser:cancelWhen:]`).
/// Here a qualified name looks the member's name up whole rather than
/// containing it: the member search stops collecting at its limit, which a
/// short name could reach before it came to the type asked for.
enum FindCrossReferenceRootResolver {
    struct Resolution: Sendable {
        var roots: [FindCrossReferenceRoot]
        /// Indexed images whose members could not be looked through, their
        /// corpus not being built yet.
        var unbuiltImageCount = 0
    }

    /// The most roots a term gives.
    static let rootLimit = 200

    static func resolve(_ query: FindQuery, engine: RuntimeEngine, generationOptions: RuntimeObjectInterface.GenerationOptions) async throws -> Resolution {
        guard let direction = query.mode.crossReferenceDirection else { return Resolution(roots: []) }
        switch direction {
        case .typeReferences:
            return try await typeRoots(for: query, engine: engine)
        case .callers, .callees:
            return try await memberRoots(for: query, engine: engine, generationOptions: generationOptions)
        }
    }

    private static func typeRoots(for query: FindQuery, engine: RuntimeEngine) async throws -> Resolution {
        let searchText = query.relationshipSearchText
        // The relationship tables know every indexed type by name; the
        // ancestors are the cheapest relationship to have them walk.
        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(
            text: searchText.text,
            matchMode: searchText.matchMode,
            relationship: .ancestors,
            isCaseSensitive: query.isCaseSensitive,
            candidateLimit: rootLimit
        ))
        var seenObjects: Set<RuntimeObjectKey> = []
        let roots = trees
            .map(\.root)
            .filter { FindCrossReferenceRoot.isReferenceableType($0) && seenObjects.insert($0.key).inserted }
            .map(FindCrossReferenceRoot.type)
        return Resolution(roots: roots)
    }

    private static func memberRoots(for query: FindQuery, engine: RuntimeEngine, generationOptions: RuntimeObjectInterface.GenerationOptions) async throws -> Resolution {
        let qualifiedName = query.term.hasPatterns ? nil : QualifiedMemberName(query.term.plainText)
        let memberQuery: RuntimeMemberSearchQuery
        if let qualifiedName {
            memberQuery = RuntimeMemberSearchQuery(
                text: "^" + NSRegularExpression.escapedPattern(for: qualifiedName.memberName) + "$",
                matchMode: .regularExpression,
                kinds: qualifiedName.isObjectiveCMethod ? [.objcMethod] : FindCrossReferenceRoot.memberKindsWithCode,
                isCaseSensitive: false,
                resultLimit: FindSession.resultLimit,
                generationOptions: generationOptions,
                imagePaths: nil
            )
        } else {
            let searchText = query.relationshipSearchText
            memberQuery = RuntimeMemberSearchQuery(
                text: searchText.text,
                matchMode: searchText.matchMode,
                kinds: FindCrossReferenceRoot.memberKindsWithCode,
                isCaseSensitive: query.isCaseSensitive,
                resultLimit: FindSession.resultLimit,
                generationOptions: generationOptions,
                imagePaths: nil
            )
        }
        let collector = FindMemberMatchCollector()
        let summary = try await engine.searchMembers(memberQuery) { batch in
            await collector.append(batch)
        }
        var seenMembers: Set<RuntimeMemberReference> = []
        var roots: [FindCrossReferenceRoot] = []
        for match in await collector.matches {
            if let qualifiedName, !qualifiedName.names(match.object) || qualifiedName.isStatic.map({ $0 != match.member.isStatic }) == true {
                continue
            }
            // Overloads share a name, and the engine takes every one of them for it.
            let member = RuntimeMemberReference(object: match.object, name: match.member.name, kind: match.member.kind, isStatic: match.member.isStatic)
            guard seenMembers.insert(member).inserted else { continue }
            roots.append(.member(member, declaration: match.member))
        }
        roots.sort { ($0.title as NSString).compare($1.title) == .orderedAscending }
        return Resolution(roots: Array(roots.prefix(rootLimit)), unbuiltImageCount: summary.unbuiltIndexedImagePaths.count)
    }

    /// Where `member` is declared in its type's interface, as the corpus of its
    /// image prints it; `nil` while that corpus is not built, or when no line
    /// of it declares the member.
    static func declaration(of member: RuntimeMemberReference, engine: RuntimeEngine, generationOptions: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeMemberDeclaration? {
        let collector = FindMemberMatchCollector()
        _ = try await engine.searchMembers(RuntimeMemberSearchQuery(
            text: "^" + NSRegularExpression.escapedPattern(for: member.name) + "$",
            matchMode: .regularExpression,
            kinds: [member.kind],
            isCaseSensitive: true,
            resultLimit: 100,
            generationOptions: generationOptions,
            imagePaths: [member.object.imagePath]
        )) { batch in
            await collector.append(batch)
        }
        return await collector.matches
            .first { $0.object == member.object && $0.member.isStatic == member.isStatic && $0.member.lineNumber != nil }?
            .member
    }
}

/// The batches a member search delivers, gathered.
actor FindMemberMatchCollector {
    private(set) var matches: [RuntimeMemberMatch] = []

    func append(_ batch: [RuntimeMemberMatch]) {
        matches.append(contentsOf: batch)
    }
}

/// A member named with its type: `-[NSWindow makeKeyAndOrderFront:]`,
/// `+[NSColor redColor]`, `NSWindow.title`, `SwiftUI.ViewGraph.updateOutputs(at:)`.
struct QualifiedMemberName: Equatable {
    var typeName: String
    /// The member's own name: a whole selector, or a Swift function's base
    /// name, the argument labels dropped — the name a member search knows it by.
    var memberName: String
    /// Whether it is a class member: `+` or `-`; `nil` when the term does not say.
    var isStatic: Bool?
    var isObjectiveCMethod: Bool

    init?(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sign = trimmedText.first, sign == "-" || sign == "+",
           trimmedText.dropFirst().first == "[", trimmedText.last == "]" {
            let inside = trimmedText.dropFirst(2).dropLast()
            let parts = inside.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { return nil }
            var typeName = String(parts[0])
            // A category method: `-[NSWindow(NSToolbarSupport) toggleToolbarShown:]`.
            if let parenthesis = typeName.firstIndex(of: "(") {
                typeName = String(typeName[..<parenthesis])
            }
            let memberName = parts[1].trimmingCharacters(in: .whitespaces)
            guard !typeName.isEmpty, !memberName.isEmpty else { return nil }
            self.typeName = typeName
            self.memberName = memberName
            self.isStatic = sign == "+"
            self.isObjectiveCMethod = true
            return
        }
        // The last dot outside an argument list or generic arguments.
        var depth = 0
        var lastDot: String.Index?
        for index in trimmedText.indices {
            switch trimmedText[index] {
            case "(", "<", "[": depth += 1
            case ")", ">", "]": depth -= 1
            case "." where depth == 0: lastDot = index
            default: break
            }
        }
        guard let lastDot else { return nil }
        let typeName = String(trimmedText[..<lastDot])
        let memberName = String(trimmedText[trimmedText.index(after: lastDot)...].prefix { $0 != "(" })
        guard !typeName.isEmpty, !memberName.isEmpty else { return nil }
        self.typeName = typeName
        self.memberName = memberName
        self.isStatic = nil
        self.isObjectiveCMethod = false
    }

    /// Whether `object` is the type the term names: by its name, or by the
    /// name its module qualifies — `ViewGraph` names `SwiftUI.ViewGraph`.
    func names(_ object: RuntimeObject) -> Bool {
        object.displayName == typeName || object.name == typeName || object.displayName.hasSuffix("." + typeName)
    }
}
