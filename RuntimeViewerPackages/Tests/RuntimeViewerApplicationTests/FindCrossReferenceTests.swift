import AppKit
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerApplication

/// The rules of Call Hierarchy, Callees and Type References that hold without an engine: how a
/// level is grouped and ordered, how a tree loads, where it stops, and how a term names a member.
///
/// On the main actor, where `FindSession` builds rows: a row's icon comes out of
/// `RuntimeObjectIcon`'s cache, which is not safe to fill from two threads at once.
@Suite("Find cross-reference trees")
@MainActor
struct FindCrossReferenceTreeTests {
    private static let image = "/System/Library/Frameworks/Sample.framework/Versions/A/Sample"
    private static let otherImage = "/usr/lib/libOther.dylib"

    private static func function(_ name: String?, address: UInt64, imagePath: String = image, member: RuntimeMemberReference? = nil) -> RuntimeFunctionReference {
        RuntimeFunctionReference(imagePath: imagePath, address: address, displayName: name, symbolName: name, member: member, foldedSymbolCount: 0)
    }

    private static func reference(from function: RuntimeFunctionReference, to target: RuntimeCrossReferenceTarget, at address: UInt64, precision: RuntimeCrossReferencePrecision = .exact, isRuntimeHelperCall: Bool = false) -> RuntimeCrossReference {
        RuntimeCrossReference(referencingFunction: function, instructionAddress: address, kind: .call, target: target, precision: precision, isRuntimeHelperCall: isRuntimeHelperCall)
    }

    private static let subject = function("subject", address: 0x1000)

    // MARK: - Grouping

    @Test("callers are one row per function, counting its calls, sure if any call is, ordered by title")
    func callersGroupByFunction() {
        let beta = Self.function("beta", address: 0x3000)
        let alpha = Self.function("alpha", address: 0x2000)
        let references = [
            Self.reference(from: beta, to: .function(Self.subject), at: 0x3004, precision: .matchedBySelector),
            Self.reference(from: alpha, to: .function(Self.subject), at: 0x2004, precision: .matchedBySelector),
            Self.reference(from: beta, to: .function(Self.subject), at: 0x3008, precision: .exact),
        ]

        let rows = FindCrossReferenceTree.rows(for: references, direction: .callers).map(\.row)

        #expect(rows.map(\.title) == ["alpha", "beta"])
        #expect(rows.map(\.referenceCount) == [1, 2])
        #expect(rows.map(\.precision) == [.matchedBySelector, .exact])
        #expect(rows[0].subtitle == "Sample · by selector")
        #expect(rows[1].subtitle == "Sample · 2 calls")
    }

    @Test("callees keep the order the function makes them, a callee called twice counted once")
    func calleesKeepInstructionOrder() {
        let zeta = Self.function("zeta", address: 0x5000)
        let alpha = Self.function("alpha", address: 0x4000)
        let references = [
            Self.reference(from: Self.subject, to: .function(zeta), at: 0x1004),
            Self.reference(from: Self.subject, to: .selector(name: "length", receiverClassName: nil), at: 0x1008, precision: .matchedBySelector),
            Self.reference(from: Self.subject, to: .function(alpha), at: 0x100C),
            Self.reference(from: Self.subject, to: .function(zeta), at: 0x1010),
        ]

        let rows = FindCrossReferenceTree.rows(for: references, direction: .callees).map(\.row)

        #expect(rows.map(\.title) == ["zeta", "length", "alpha"])
        #expect(rows.map(\.referenceCount) == [2, 1, 1])
        #expect(rows[0].expandableFunction == zeta, "a function callee loads its own callees")
        #expect(rows[1].expandableFunction == nil, "a message has no function to load")
    }

    @Test("type references group by image, then by function, each ordered by title as Xcode orders them")
    func typeReferencesGroupByImage() {
        let inSample = Self.function("useSample", address: 0x2000)
        let inOther = Self.function("useOther", address: 0x9000, imagePath: Self.otherImage)
        let type = RuntimeCrossReferenceTarget.type(name: "Thing", object: nil)
        let references = [
            Self.reference(from: inSample, to: type, at: 0x2004),
            Self.reference(from: inOther, to: type, at: 0x9004),
            Self.reference(from: inSample, to: type, at: 0x2008),
        ]

        let loadedRows = FindCrossReferenceTree.rows(for: references, direction: .typeReferences)

        // `-[NSString compare:]` is literal: capitals come first.
        #expect(loadedRows.map(\.row.title) == ["Sample", "libOther.dylib"])
        #expect(loadedRows.map(\.row.referenceCount) == [2, 1])
        #expect(loadedRows[0].children.map(\.row.title) == ["useSample"])
        #expect(loadedRows[0].children[0].row.referenceCount == 2)
        #expect(loadedRows[0].children[0].row.expandableFunction == nil, "a referencing function is where Type References stops")
    }

    // MARK: - Unnamed functions

    @Test("callers nothing names go below one last row, after the named ones in title order")
    func unnamedCallersAreGatheredLast() throws {
        let beta = Self.function("beta", address: 0x3000)
        let alpha = Self.function("alpha", address: 0x2000)
        let firstUnnamed = Self.function(nil, address: 0x4000)
        let secondUnnamed = Self.function(nil, address: 0x5000)
        let references = [
            Self.reference(from: secondUnnamed, to: .function(Self.subject), at: 0x5004),
            Self.reference(from: beta, to: .function(Self.subject), at: 0x3004),
            Self.reference(from: firstUnnamed, to: .function(Self.subject), at: 0x4004),
            Self.reference(from: firstUnnamed, to: .function(Self.subject), at: 0x4008),
            Self.reference(from: alpha, to: .function(Self.subject), at: 0x2004),
        ]

        let loadedRows = FindCrossReferenceTree.rows(for: references, direction: .callers)

        #expect(loadedRows.map(\.row.title) == ["alpha", "beta", "Unnamed Functions"])
        let gatheringRow = try #require(loadedRows.last)
        #expect(gatheringRow.row.item == .unnamedFunctions(count: 2))
        #expect(gatheringRow.row.subtitle == "2 functions · 3 calls")
        #expect(gatheringRow.children.map(\.row.item) == [.function(firstUnnamed), .function(secondUnnamed)])
        #expect(gatheringRow.row.navigationTarget == nil)
    }

    @Test("callees nothing names go below one last row, the others keeping the order they are made in")
    func unnamedCalleesAreGatheredLast() {
        let zeta = Self.function("zeta", address: 0x5000)
        let unnamed = Self.function(nil, address: 0x6000)
        let alpha = Self.function("alpha", address: 0x4000)
        let references = [
            Self.reference(from: Self.subject, to: .function(zeta), at: 0x1004),
            Self.reference(from: Self.subject, to: .function(unnamed), at: 0x1008),
            Self.reference(from: Self.subject, to: .function(alpha), at: 0x100C),
        ]

        let rows = FindCrossReferenceTree.rows(for: references, direction: .callees).map(\.row)

        #expect(rows.map(\.title) == ["zeta", "alpha", "Unnamed Functions"])
    }

    @Test("under each image of a type's references, the functions nothing names go below one last row")
    func unnamedTypeReferencesAreGatheredUnderTheirImage() {
        let named = Self.function("useSample", address: 0x2000)
        let unnamed = Self.function(nil, address: 0x3000)
        let type = RuntimeCrossReferenceTarget.type(name: "Thing", object: nil)

        let loadedRows = FindCrossReferenceTree.rows(for: [
            Self.reference(from: unnamed, to: type, at: 0x3004),
            Self.reference(from: named, to: type, at: 0x2004),
        ], direction: .typeReferences)

        #expect(loadedRows.map(\.row.title) == ["Sample"])
        #expect(loadedRows[0].children.map(\.row.title) == ["useSample", "Unnamed Functions"])
        #expect(loadedRows[0].children[1].children.map(\.row.item) == [.function(unnamed)])
    }

    @Test("the row gathering them shows collapsed, and each function below it still loads its own callers")
    func gatheredFunctionsShowCollapsedAndStillLoad() throws {
        let unnamed = Self.function(nil, address: 0x4000)
        var tree = FindCrossReferenceTree(direction: .callers, roots: [.function(Self.subject)])
        let rootIdentifier = tree.rootIdentifier(at: 0)
        tree.setLoadState(.loaded(FindCrossReferenceTree.rows(for: [
            Self.reference(from: unnamed, to: .function(Self.subject), at: 0x4004),
        ], direction: .callers)), of: rootIdentifier)

        let built = tree.build(showsRuntimeHelperCalls: false)

        let gatheringNode = try #require(built.nodes.first?.children.first)
        #expect(gatheringNode.identifier == rootIdentifier + "/~unnamed")
        // The tree shows expanded what it opened — its roots — and what the user opened.
        #expect(!tree.expandedIdentifiers.contains(gatheringNode.identifier))
        #expect(built.loadRequests[gatheringNode.identifier] == nil, "its functions came with the level")
        let unnamedNode = try #require(gatheringNode.children.first)
        #expect(built.loadRequests[unnamedNode.identifier] == .calls(.function(imagePath: Self.image, address: 0x4000)))
    }

    // MARK: - Icons

    @Test("a function's icon takes the colour of its language: Swift blue, C and C++ green, Objective-C orange, none grey")
    func functionIconsTakeTheirLanguagesColours() {
        let size = FindResultCellStyle.Metrics.navigator.iconSize
        func icon(of item: FindCrossReferenceRow.Item) -> NSImage? {
            FindResultNode.crossReference(FindCrossReferenceRow(item: item, direction: .callers), identifier: "row", children: []).appearance.icon
        }
        func badge(_ text: String, _ color: IDEIconColor) -> NSImage {
            RuntimeObjectIcon.icon(text: text, color: color, size: size)
        }
        let thing = RuntimeObject(name: "SampleThing", displayName: "SampleThing", kind: .objc(.type(.class)), imagePath: Self.image, children: [])
        let swiftSymbol = RuntimeFunctionReference(imagePath: Self.image, address: 0x2000, displayName: "Sample.Thing.run()", symbolName: "_$s6Sample5ThingV3runyyF", member: nil, foldedSymbolCount: 0)
        // Rebuilt from Swift metadata: no symbol.
        let swiftMetadataName = RuntimeFunctionReference(imagePath: Self.image, address: 0x2100, displayName: "type metadata accessor for Sample.Thing", symbolName: nil, member: nil, foldedSymbolCount: 0)
        let objectiveCMethod = RuntimeFunctionReference(
            imagePath: Self.image, address: 0x2200, displayName: "-[SampleThing run]", symbolName: "-[SampleThing run]",
            member: RuntimeMemberReference(object: thing, name: "run", kind: .objcMethod, isStatic: false), foldedSymbolCount: 0
        )

        #expect(icon(of: .function(swiftSymbol)) === badge("f", .blue))
        #expect(icon(of: .function(swiftMetadataName)) === badge("f", .blue))
        #expect(icon(of: .function(Self.function("_sample_run", address: 0x2300))) === badge("f", .green))
        #expect(icon(of: .function(Self.function("__ZN6Sample3runEv", address: 0x2400))) === badge("f", .green))
        #expect(icon(of: .function(objectiveCMethod)) === badge("M", .orange))
        #expect(icon(of: .function(Self.function(nil, address: 0x2500))) === badge("f", .gray))
        // A callee another image exports, by its symbol.
        #expect(icon(of: .target(.importedSymbol(name: "_$sSS5countSivg"))) === badge("f", .blue))
        #expect(icon(of: .target(.importedSymbol(name: "_strlen"))) === badge("f", .green))
        #expect(icon(of: .unnamedFunctions(count: 3)) === badge("f", .gray))
    }

    // MARK: - Loading

    @Test("a row not loaded has one row standing in for its level; one that loaded nothing has none")
    func unloadedRowsShowALoadingRow() throws {
        var tree = FindCrossReferenceTree(direction: .callers, roots: [.function(Self.subject)])
        let rootIdentifier = tree.rootIdentifier(at: 0)

        let unloaded = tree.build(showsRuntimeHelperCalls: false)
        let loadingRow = try #require(unloaded.nodes.first?.children.first)
        #expect(unloaded.nodes.first?.children.count == 1)
        #expect(loadingRow.identifier == rootIdentifier + "/~loading")
        #expect(unloaded.loadRequests[rootIdentifier] == .calls(.function(imagePath: Self.image, address: 0x1000)))

        tree.setLoadState(.loaded([]), of: rootIdentifier)
        #expect(tree.build(showsRuntimeHelperCalls: false).nodes.first?.children.isEmpty == true)

        tree.setLoadState(.failed("No luck"), of: rootIdentifier)
        guard case .crossReference(let failureRow)? = tree.build(showsRuntimeHelperCalls: false).nodes.first?.children.first?.content else {
            Issue.record("expected the failure row")
            return
        }
        #expect(failureRow.item == .failure(message: "No luck"))
    }

    @Test("a call back into the root or into a function above it is marked, and loads nothing more")
    func recursionStopsTheBranch() throws {
        let caller = Self.function("caller", address: 0x2000)
        var tree = FindCrossReferenceTree(direction: .callers, roots: [.function(Self.subject)])
        let rootIdentifier = tree.rootIdentifier(at: 0)
        tree.setLoadState(.loaded(FindCrossReferenceTree.rows(for: [
            Self.reference(from: caller, to: .function(Self.subject), at: 0x2004),
            Self.reference(from: Self.subject, to: .function(Self.subject), at: 0x1004),
        ], direction: .callers)), of: rootIdentifier)
        let callerIdentifier = rootIdentifier + "/" + FindCrossReferenceTree.key(of: .function(caller))
        // The caller's own caller is the root's subject again.
        tree.setLoadState(.loaded(FindCrossReferenceTree.rows(for: [
            Self.reference(from: Self.subject, to: .function(caller), at: 0x1008),
        ], direction: .callers)), of: callerIdentifier)

        let built = tree.build(showsRuntimeHelperCalls: false)
        let rows = try #require(built.nodes.first?.children)

        guard case .crossReference(let callerRow) = rows[0].content, case .crossReference(let selfRow) = rows[1].content else {
            Issue.record("expected two cross-reference rows")
            return
        }
        #expect(callerRow.isRecursive == false)
        #expect(selfRow.isRecursive, "the subject calling itself")
        #expect(rows[1].children.isEmpty)
        #expect(built.loadRequests[rows[1].identifier] == nil)

        guard case .crossReference(let backAtTheRoot)? = rows[0].children.first?.content else {
            Issue.record("expected the caller's level")
            return
        }
        #expect(backAtTheRoot.isRecursive, "the caller's caller is the root again")
        #expect(rows[0].identifier.hasPrefix(rootIdentifier + "/"), "a row is named by its path from the root")
    }

    @Test("runtime helper calls are left out of callees until shown")
    func runtimeHelperCallsAreHiddenUntilShown() throws {
        let retain = Self.function("objc_retain", address: 0x7000, imagePath: "/usr/lib/libobjc.A.dylib")
        let work = Self.function("work", address: 0x2000)
        var tree = FindCrossReferenceTree(direction: .callees, roots: [.function(Self.subject)])
        tree.setLoadState(.loaded(FindCrossReferenceTree.rows(for: [
            Self.reference(from: Self.subject, to: .function(retain), at: 0x1004, isRuntimeHelperCall: true),
            Self.reference(from: Self.subject, to: .function(work), at: 0x1008),
        ], direction: .callees)), of: tree.rootIdentifier(at: 0))

        #expect(tree.build(showsRuntimeHelperCalls: false).nodes.first?.children.count == 1)
        #expect(tree.build(showsRuntimeHelperCalls: true).nodes.first?.children.count == 2)
    }

    @Test("roots open as they arrive only while there are few of them")
    func fewRootsOpenByThemselves() {
        let fewRoots = (0 ..< FindCrossReferenceTree.automaticallyExpandedRootLimit).map { FindCrossReferenceRoot.function(Self.function("f\($0)", address: UInt64(0x1000 + $0 * 16))) }
        let fewRootsTree = FindCrossReferenceTree(direction: .callers, roots: fewRoots)
        #expect(fewRootsTree.expandedIdentifiers.count == fewRoots.count)

        let manyRoots = fewRoots + [.function(Self.function("one more", address: 0x9000))]
        #expect(FindCrossReferenceTree(direction: .callers, roots: manyRoots).expandedIdentifiers.isEmpty)
    }

    @Test("a member root does not load in Type References, nor a type root in the calls")
    func rootsLoadOnlyInAModeTheyFit() {
        let member = RuntimeMemberReference(object: FindResultFixtures.object(named: "Thing"), name: "run", kind: .objcMethod, isStatic: false)
        let type = FindResultFixtures.object(named: "Thing")

        let memberInTypeReferences = FindCrossReferenceTree(direction: .typeReferences, roots: [.member(member, declaration: nil)]).build(showsRuntimeHelperCalls: false)
        #expect(memberInTypeReferences.loadRequests.isEmpty)
        #expect(memberInTypeReferences.nodes.first?.children.isEmpty == true)

        let typeInCallers = FindCrossReferenceTree(direction: .callers, roots: [.type(type)]).build(showsRuntimeHelperCalls: false)
        #expect(typeInCallers.loadRequests.isEmpty)

        var query = FindQuery(mode: .callHierarchy, crossReferenceRoot: .member(member, declaration: nil))
        FindModePathChoice.mode(.callees).apply(to: &query)
        #expect(query.crossReferenceRoot != nil, "a member has callees too")
        FindModePathChoice.mode(.typeReferences).apply(to: &query)
        #expect(query.crossReferenceRoot == nil)
    }

    // MARK: - Names

    @Test("a term qualified by its type is split into the type and the member's own name")
    func qualifiedNames() throws {
        let instanceMethod = try #require(QualifiedMemberName("-[NSWindow makeKeyAndOrderFront:]"))
        #expect(instanceMethod.typeName == "NSWindow")
        #expect(instanceMethod.memberName == "makeKeyAndOrderFront:")
        #expect(instanceMethod.isStatic == false)
        #expect(instanceMethod.isObjectiveCMethod)

        let classMethod = try #require(QualifiedMemberName("+[NSColor redColor]"))
        #expect(classMethod.isStatic == true)

        let categoryMethod = try #require(QualifiedMemberName("-[NSWindow(NSToolbarSupport) toggleToolbarShown:]"))
        #expect(categoryMethod.typeName == "NSWindow")

        let swiftMethod = try #require(QualifiedMemberName("SwiftUI.ViewGraph.updateOutputs(at:)"))
        #expect(swiftMethod.typeName == "SwiftUI.ViewGraph")
        #expect(swiftMethod.memberName == "updateOutputs")
        #expect(swiftMethod.isStatic == nil)

        let genericSubscript = try #require(QualifiedMemberName("Dictionary<String, Int>.subscript"))
        #expect(genericSubscript.typeName == "Dictionary<String, Int>")

        #expect(QualifiedMemberName("makeKeyAndOrderFront:") == nil)
        #expect(QualifiedMemberName(".hidden") == nil)

        let swiftType = FindResultFixtures.object(named: "SwiftUI.ViewGraph")
        #expect(QualifiedMemberName("ViewGraph.updateOutputs")?.names(swiftType) == true)
        #expect(QualifiedMemberName("Graph.updateOutputs")?.names(swiftType) == false)
    }

    @Test("rows name members by type, and functions nothing names by address")
    func titles() {
        let window = FindResultFixtures.object(named: "NSWindow")
        #expect(FindCrossReferenceNaming.title(of: RuntimeMemberReference(object: window, name: "makeKeyAndOrderFront:", kind: .objcMethod, isStatic: false)) == "-[NSWindow makeKeyAndOrderFront:]")
        #expect(FindCrossReferenceNaming.title(of: RuntimeMemberReference(object: window, name: "title", kind: .objcProperty, isStatic: false)) == "NSWindow.title")
        #expect(FindCrossReferenceNaming.title(of: Self.function(nil, address: 0x184AE35C0)) == "Unnamed function 0x184AE35C0")
        #expect(FindCrossReferenceNaming.title(of: .selector(name: "orderOut:", receiverClassName: "NSWindow")) == "[NSWindow orderOut:]")
        #expect(FindCrossReferenceNaming.title(of: .importedSymbol(name: "_CFRelease")) == "CFRelease")
        #expect(FindCrossReferenceNaming.title(of: .importedSymbol(name: "_$s4main3fooyyF")) == "_$s4main3fooyyF")
    }

    @Test("the call modes take Xcode's placeholder and match styles; Callees has no scope")
    func modes() {
        #expect(FindMode.callHierarchy.searchFieldPlaceholder == "Method, Property, or Function")
        #expect(FindMode.allCases.filter(\.loadsChildrenLazily) == [.callHierarchy, .callees, .typeReferences])
        let crossReferenceModesHaveMatchStyles = [FindMode.callHierarchy, .callees, .typeReferences].allSatisfy { $0.hasTextMatchStyles }
        #expect(crossReferenceModesHaveMatchStyles)
        #expect(FindMode.allCases.filter { !$0.usesScope } == [.callees])
        #expect(FindModePathComponent.path(for: FindQuery(mode: .callHierarchy)).map(\.title) == ["Find", "Call Hierarchy", "Containing"])
    }
}

/// Call Hierarchy, Callees and Type References as the page drives them, on the shared test engine.
/// Every query is held to Foundation, so a level is one image's scan.
@Suite("FindViewModel cross references", .serialized)
@MainActor
struct FindViewModelCrossReferenceTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let modePathChoiceSelectedRelay = PublishRelay<FindModePathChoice>()
    private let searchCommittedRelay = PublishRelay<FindQueryTerm>()
    private let recentQuerySelectedRelay = PublishRelay<FindQuery>()
    private let filterStringRelay = BehaviorRelay<String>(value: "")
    private let resultClickedRelay = PublishRelay<FindResultNode>()
    private let resultCollapsedRelay = PublishRelay<FindResultNode>()
    private let resultExpandedRelay = PublishRelay<FindResultNode>()
    private let crossReferenceCommandSelectedRelay = PublishRelay<FindCrossReferenceCommand>()
    private let runtimeHelperCallsToggledRelay = PublishRelay<Bool>()

    /// `-[NSMutableString appendString:]`, which Foundation calls from many places.
    private static func appendString(on engine: RuntimeEngine) async throws -> RuntimeMemberReference {
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        return RuntimeMemberReference(object: mutableString, name: "appendString:", kind: .objcMethod, isStatic: false)
    }

    /// The query a command runs for `root`, held to the image the root is in.
    private static func query(_ mode: FindMode, for root: FindCrossReferenceRoot) -> FindQuery {
        var query = FindQuery().crossReferenceQuery(mode, for: root)
        query.scope = .images([root.imagePath])
        return query
    }

    /// The rows below the first root once its level has loaded.
    private static func loadedLevel(of nodes: [FindResultNode]) -> [FindResultNode]? {
        guard let root = nodes.first, !root.children.contains(where: isLoadingRow) else { return nil }
        return root.children
    }

    private static func isLoadingRow(_ node: FindResultNode) -> Bool {
        if case .crossReference(let row) = node.content, row.item == .loading { return true }
        return false
    }

    private static func row(of node: FindResultNode) -> FindCrossReferenceRow? {
        if case .crossReference(let row) = node.content { return row }
        return nil
    }

    @Test("Call Hierarchy opens its root and loads its callers; expanding a caller loads the next level")
    func callHierarchyLoadsLevelByLevel() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)

        recentQuerySelectedRelay.accept(Self.query(.callHierarchy, for: .member(member, declaration: nil)))

        let nodes = try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0)?.isEmpty == false }
        let root = try #require(nodes.first)
        guard case .crossReferenceRoot(.member(let rootMember, _), .callers) = root.content else {
            Issue.record("expected the member as the root")
            return
        }
        #expect(rootMember == member)
        let callers = try #require(Self.loadedLevel(of: nodes))
        #expect(callers.allSatisfy { Self.row(of: $0)?.item.isFunction == true })
        #expect(callers.allSatisfy { Self.row(of: $0).map { $0.subtitle.hasPrefix("Foundation") } == true }, "the scope holds the callers to Foundation")
        #expect(environment.documentState.findSession.crossReferenceExpandedIdentifiers.contains(root.identifier))
        #expect(try await nextValue(from: output.isSearching) { !$0 } == false)
        #expect(try await nextValue(from: output.summary) == nil, "Xcode's call hierarchy has no summary row")
        #expect(try await nextValue(from: output.isFilterEnabled) == false)

        // A caller that is no recursion loads its own callers when expanded.
        let caller = try #require(callers.first { Self.row(of: $0)?.isRecursive == false })
        resultExpandedRelay.accept(caller)
        let expandedNodes = try await nextValue(from: output.nodes, timeout: 60) { nodes in
            guard let reloadedCaller = nodes.first?.children.first(where: { $0.identifier == caller.identifier }) else { return false }
            return !reloadedCaller.children.contains(where: Self.isLoadingRow)
        }
        #expect(environment.documentState.findSession.crossReferenceExpandedIdentifiers.contains(caller.identifier))
        #expect(expandedNodes.first?.children.first { $0.identifier == caller.identifier }?.children.allSatisfy { $0.identifier.hasPrefix(caller.identifier + "/") } == true)
    }

    @Test("with Keep Cross References Ready on, a level reads the prepared cross references and lists what a scan lists")
    func preparedLevelsListWhatScansList() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let member = try await Self.appendString(on: engine)
        let query = Self.query(.callHierarchy, for: .member(member, declaration: nil))

        func loadedCallerTitles(isPreparing: Bool) async throws -> [String] {
            let environment = ViewModelTestEnvironment(runtimeEngine: engine)
            environment.settings.search.isCrossReferencePreparationEnabled = isPreparing
            let (viewModel, output) = makeViewModel(in: environment)
            defer { withExtendedLifetime(viewModel) {} }
            recentQuerySelectedRelay.accept(query)
            let nodes = try await nextValue(from: output.nodes, timeout: 120) { Self.loadedLevel(of: $0)?.isEmpty == false }
            return try #require(Self.loadedLevel(of: nodes)).compactMap { Self.row(of: $0)?.title }
        }
        let scanned = try await loadedCallerTitles(isPreparing: false)
        let prepared = try await loadedCallerTitles(isPreparing: true)
        #expect(!prepared.isEmpty)
        #expect(prepared == scanned)
    }

    @Test("expanding a row starts its level on the main actor's next turn, never inside the expansion")
    func expansionNeverPublishesWhileThePageApplies() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)
        recentQuerySelectedRelay.accept(Self.query(.callHierarchy, for: .member(member, declaration: nil)))
        let callers = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0)?.isEmpty == false }))
        let caller = try #require(callers.first { Self.row(of: $0)?.isRecursive == false })
        let session = environment.documentState.findSession
        var publishedCount = 0
        let subscription = session.$results.asObservable().subscribeOnNext { _ in publishedCount += 1 }
        defer { subscription.dispose() }
        let publishedBefore = publishedCount

        // What the page does while it applies published rows: put an expansion back.
        session.crossReferenceRowDidExpand(caller.identifier)
        #expect(publishedCount == publishedBefore, "rows published from inside the expansion reach the page while it applies the last ones")

        _ = try await nextValue(from: output.nodes, timeout: 60) { nodes in
            nodes.first?.children.first { $0.identifier == caller.identifier }.map { !$0.children.contains(where: Self.isLoadingRow) } == true
        }
        #expect(publishedCount > publishedBefore)
    }

    @Test("Callees lists what the member calls, the runtime helper calls only once shown")
    func calleesWithAndWithoutRuntimeHelperCalls() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)

        recentQuerySelectedRelay.accept(Self.query(.callees, for: .member(member, declaration: nil)))
        let callees = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0)?.isEmpty == false }))
        #expect(try await nextValue(from: output.isRuntimeHelperCallsToggleShown) == true)
        #expect(try await nextValue(from: output.isScopeEnabled) == false)
        #expect(callees.allSatisfy { Self.row(of: $0)?.isRuntimeHelperCall == false })

        runtimeHelperCallsToggledRelay.accept(true)
        #expect(try await nextValue(from: output.showsRuntimeHelperCalls) { $0 } == true)
        let calleesWithHelpers = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes)))
        #expect(calleesWithHelpers.count >= callees.count)
    }

    @Test("Type References groups the functions using a type under their image")
    func typeReferencesGroupUnderTheImage() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let mutableString = try await engine.runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)

        recentQuerySelectedRelay.accept(Self.query(.typeReferences, for: .type(mutableString)))

        let images = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0)?.isEmpty == false }))
        #expect(images.count == 1, "the scope is Foundation alone")
        // Named as the engine's process names the image, which need not be the path it was loaded by.
        #expect(Self.row(of: images[0])?.title == "Foundation")
        #expect(images[0].children.isEmpty == false)
        #expect(images[0].children.allSatisfy { Self.row(of: $0)?.item.isFunction == true })
    }

    @Test("a scope of several images asks for each by its own path, however the results spell them")
    func scopesOfSeveralImages() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)

        // The test engine knows Foundation by its framework's symlink; the engine's process lists
        // it under the path the shared cache gives it.
        var query = Self.query(.callHierarchy, for: .member(member, declaration: nil))
        query.scope = .images([TestImages.foundation, TestImages.libobjc])
        recentQuerySelectedRelay.accept(query)

        let callers = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0) != nil }))
        #expect(callers.isEmpty == false)
        #expect(callers.allSatisfy { Self.row(of: $0)?.item.isFunction == true })
    }

    @Test("a term finds its roots in the corpus; an edited term drops a command's root")
    func termsFindRoots() async throws {
        let engine = try await TestRuntimeEngine.shared()
        _ = try await engine.buildInterfaceCorpus(for: TestImages.foundation, transformer: .default)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)

        var query = Self.query(.callHierarchy, for: .member(member, declaration: nil))
        query.crossReferenceRoot = nil
        recentQuerySelectedRelay.accept(query)

        let nodes = try await nextValue(from: output.nodes, timeout: 60) { !$0.isEmpty }
        let rootTitles = nodes.compactMap { node -> String? in
            if case .crossReferenceRoot(let root, _) = node.content { return root.title }
            return nil
        }
        #expect(rootTitles == ["-[NSMutableString appendString:]"])
        guard case .crossReferenceRoot(.member(_, let declaration?), _) = nodes[0].content else {
            Issue.record("a root a term found knows its declaration")
            return
        }
        #expect(declaration.lineNumber != nil)

        // Return on an edited term matches names again.
        recentQuerySelectedRelay.accept(Self.query(.callHierarchy, for: .member(member, declaration: nil)))
        _ = try await nextValue(from: output.query) { $0.crossReferenceRoot != nil }
        searchCommittedRelay.accept("appendFormat:")
        #expect(try await nextValue(from: output.query) { $0.term.plainText == "appendFormat:" }.crossReferenceRoot == nil)
    }

    @Test("Find Call Hierarchy on a member row roots a new query at the member, the scope reset")
    func commandOnAMemberRow() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)
        let declaration = RuntimeMemberDeclaration(name: member.name, kind: member.kind, isStatic: false, declarationText: "- (void)appendString:(NSString *)aString;", lineNumber: 12)
        let memberRow = FindResultNode.member(RuntimeMemberMatch(object: member.object, member: declaration, matchRangeInName: RuntimeTextRange(location: 0, length: 6)), index: 0)
        #expect(memberRow.crossReferenceModes == [.callHierarchy, .callees])

        crossReferenceCommandSelectedRelay.accept(FindCrossReferenceCommand(node: memberRow, mode: .callHierarchy))

        let query = try await nextValue(from: output.query) { $0.mode == .callHierarchy }
        #expect(query.crossReferenceRoot == .member(member, declaration: declaration))
        #expect(query.term.plainText == "-[NSMutableString appendString:]")
        #expect(query.scope == .allIndexedImages)
    }

    @Test("clicking a caller that implements a member goes to its type")
    func clickingACallerGoesToItsType() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let member = try await Self.appendString(on: engine)

        recentQuerySelectedRelay.accept(Self.query(.callHierarchy, for: .member(member, declaration: nil)))
        let callers = try #require(Self.loadedLevel(of: try await nextValue(from: output.nodes, timeout: 60) { Self.loadedLevel(of: $0)?.isEmpty == false }))
        let caller = try #require(callers.first { node in
            if case .function(let function)? = Self.row(of: node)?.item { return function.member != nil }
            return false
        })
        guard case .function(let function)? = Self.row(of: caller)?.item, let callerMember = function.member else { return }

        let routes = try await selectionRoutes(of: environment) {
            resultClickedRelay.accept(caller)
        }

        #expect(environment.documentState.selectedRuntimeObject == callerMember.object)
        #expect(routes.isEmpty == false)
    }

    // MARK: - Support

    /// The routes the document takes while `action` runs and the lookups it starts finish.
    private func selectionRoutes(of environment: ViewModelTestEnvironment, timeout: TimeInterval = 30, during action: () -> Void) async throws -> [SelectionRoute] {
        var routes: [SelectionRoute] = []
        let routeSubscription = environment.documentState.routeSignal.emitOnNext { routes.append($0) }
        defer { routeSubscription.dispose() }
        action()
        let deadline = Date().addingTimeInterval(timeout)
        while routes.isEmpty, Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        return routes
    }

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (FindViewModel<SidebarRootRoute>, FindViewModel<SidebarRootRoute>.Output) {
        let viewModel = environment.make {
            FindViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(.init(
            modePathChoiceSelected: modePathChoiceSelectedRelay.asSignal(),
            memberKindFilterSelected: .empty(),
            caseSensitiveToggled: .empty(),
            scopeMenuChoiceSelected: .empty(),
            searchCommitted: searchCommittedRelay.asSignal(),
            recentQuerySelected: recentQuerySelectedRelay.asSignal(),
            clearRecentQueriesSelected: .empty(),
            filter: filterStringRelay.asDriver().map { NavigatorTextFilter(typedText: $0) },
            resultClicked: resultClickedRelay.asSignal(),
            resultOpenedInNewTab: .empty(),
            resultCollapsed: resultCollapsedRelay.asSignal(),
            resultExpanded: resultExpandedRelay.asSignal(),
            resultsSelected: .empty(),
            crossReferenceCommandSelected: crossReferenceCommandSelectedRelay.asSignal(),
            runtimeHelperCallsToggled: runtimeHelperCallsToggledRelay.asSignal()
        ))
        return (viewModel, output)
    }
}

extension FindCrossReferenceRow.Item {
    fileprivate var isFunction: Bool {
        if case .function = self { return true }
        return false
    }
}
