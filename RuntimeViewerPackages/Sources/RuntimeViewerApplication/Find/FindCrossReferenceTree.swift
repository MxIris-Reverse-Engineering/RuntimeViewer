import Foundation
import RuntimeViewerCore
import RuntimeViewerCrossReferences

/// The tree a Call Hierarchy, Callees or Type References search shows: its
/// roots, and below each row what was loaded when the row was first expanded.
///
/// Xcode's call hierarchy works this way
/// (`-[IDEBatchFindHierarchyResult lazilyFaultsChildren]`): a row not loaded
/// yet always shows a disclosure triangle, expanding it loads its level
/// (`-userIsAttemptingToViewFaultedChildrenOfItem:`), a row that loads nothing
/// loses its triangle, the roots open as they arrive, a call that comes back
/// to a function higher up its own branch is marked and loads nothing more,
/// and every level is sorted by title (`-compareText:`). Two things differ.
/// A caller is one row however many times it calls — Xcode lists each call
/// site, but a call site here is an instruction address with no source line
/// to tell two apart, so the row counts them instead. And until its level
/// arrives an expanded row shows a row saying so: a scan of the shared cache
/// takes seconds, where Xcode's index answers at once.
///
/// A value: `FindSession` keeps one per search and builds the outline's rows
/// from it each time something loads.
struct FindCrossReferenceTree {
    /// What a row's children are loaded from.
    enum LoadRequest: Equatable {
        /// The callers or callees of a member or a function.
        case calls(RuntimeCrossReferenceSubject)
        /// The functions referencing a type.
        case typeReferences(RuntimeObject)
    }

    /// Where a row's children stand.
    enum LoadState: Equatable {
        case loading
        case loaded([LoadedRow])
        case failed(String)
    }

    /// A row a load brought, with the rows that came with it: an image's
    /// functions, under a type's references. Rows that load their own
    /// children come with none.
    struct LoadedRow: Equatable {
        var row: FindCrossReferenceRow
        var children: [LoadedRow] = []
    }

    let direction: FindCrossReferenceDirection

    let roots: [FindCrossReferenceRoot]

    private var loadStates: [String: LoadState] = [:]

    /// The rows shown expanded, by identifier: the roots it opened itself, and
    /// every row the user expanded and has not collapsed since.
    private(set) var expandedIdentifiers: Set<String> = []

    /// The most roots that open — and load — as they arrive. A term that
    /// matches more leaves them closed for the user to pick from: each one
    /// costs a scan, where Xcode's index answers at once.
    static let automaticallyExpandedRootLimit = 10

    init(direction: FindCrossReferenceDirection, roots: [FindCrossReferenceRoot]) {
        self.direction = direction
        self.roots = roots
        if roots.count <= Self.automaticallyExpandedRootLimit {
            expandedIdentifiers = Set(roots.indices.map(rootIdentifier(at:)))
        }
    }

    // MARK: - State

    func loadState(of identifier: String) -> LoadState? {
        loadStates[identifier]
    }

    var isLoading: Bool {
        loadStates.values.contains(.loading)
    }

    mutating func setLoadState(_ state: LoadState, of identifier: String) {
        loadStates[identifier] = state
    }

    /// Forgets the row's level, which then loads again when the row is next
    /// expanded.
    mutating func clearLoadState(of identifier: String) {
        loadStates[identifier] = nil
    }

    mutating func expand(_ identifier: String) {
        expandedIdentifiers.insert(identifier)
    }

    mutating func collapse(_ identifier: String) {
        expandedIdentifiers.remove(identifier)
    }

    // MARK: - Rows

    /// The outline's rows, and what each expandable row would load. The
    /// runtime helper calls among the callees are left out unless
    /// `showsRuntimeHelperCalls`.
    func build(showsRuntimeHelperCalls: Bool) -> (nodes: [FindResultNode], loadRequests: [String: LoadRequest]) {
        var loadRequests: [String: LoadRequest] = [:]
        var nodes: [FindResultNode] = []
        nodes.reserveCapacity(roots.count)
        for (index, root) in roots.enumerated() {
            let identifier = rootIdentifier(at: index)
            let request: LoadRequest?
            switch root {
            case .type(let object):
                request = direction == .typeReferences ? .typeReferences(object) : nil
            case .member, .function:
                request = root.fits(direction) ? root.subject.map(LoadRequest.calls) : nil
            }
            var children: [FindResultNode] = []
            if let request {
                loadRequests[identifier] = request
                children = childNodes(of: identifier, root: root, ancestors: [], showsRuntimeHelperCalls: showsRuntimeHelperCalls, loadRequests: &loadRequests)
            }
            nodes.append(.crossReferenceRoot(root, direction: direction, identifier: identifier, children: children))
        }
        return (nodes, loadRequests)
    }

    /// The rows below an expandable row: what it loaded, or one row standing
    /// in for what it has not, which gives it its disclosure triangle.
    private func childNodes(of identifier: String, root: FindCrossReferenceRoot, ancestors: [RuntimeFunctionReference], showsRuntimeHelperCalls: Bool, loadRequests: inout [String: LoadRequest]) -> [FindResultNode] {
        switch loadStates[identifier] {
        case nil, .loading:
            return [.crossReference(FindCrossReferenceRow(item: .loading, direction: direction), identifier: identifier + "/~loading", children: [])]
        case .failed(let message):
            return [.crossReference(FindCrossReferenceRow(item: .failure(message: message), direction: direction), identifier: identifier + "/~failure", children: [])]
        case .loaded(let loadedRows):
            return nodes(for: loadedRows, under: identifier, root: root, ancestors: ancestors, showsRuntimeHelperCalls: showsRuntimeHelperCalls, loadRequests: &loadRequests)
        }
    }

    private func nodes(for loadedRows: [LoadedRow], under parentIdentifier: String, root: FindCrossReferenceRoot, ancestors: [RuntimeFunctionReference], showsRuntimeHelperCalls: Bool, loadRequests: inout [String: LoadRequest]) -> [FindResultNode] {
        var rowNodes: [FindResultNode] = []
        for loadedRow in loadedRows {
            if loadedRow.row.isRuntimeHelperCall, !showsRuntimeHelperCalls {
                continue
            }
            var row = loadedRow.row
            if case .function(let function) = row.item, row.direction != .typeReferences,
               root.contains(function) || ancestors.contains(where: { $0.imagePath == function.imagePath && $0.address == function.address }) {
                row = FindCrossReferenceRow(item: row.item, direction: row.direction, referenceCount: row.referenceCount, precision: row.precision, isRecursive: true, isRuntimeHelperCall: row.isRuntimeHelperCall)
            }
            let identifier = parentIdentifier + "/" + Self.key(of: row.item)
            var children: [FindResultNode] = []
            if !loadedRow.children.isEmpty {
                children = nodes(for: loadedRow.children, under: identifier, root: root, ancestors: ancestors, showsRuntimeHelperCalls: showsRuntimeHelperCalls, loadRequests: &loadRequests)
            } else if let function = row.expandableFunction {
                loadRequests[identifier] = .calls(.function(imagePath: function.imagePath, address: function.address))
                children = childNodes(of: identifier, root: root, ancestors: ancestors + [function], showsRuntimeHelperCalls: showsRuntimeHelperCalls, loadRequests: &loadRequests)
            }
            rowNodes.append(.crossReference(row, identifier: identifier, children: children))
        }
        return rowNodes
    }

    // MARK: - Identifiers

    /// A root's identifier. The roots of one search are distinct, so its
    /// position is enough to tell them apart; the direction keeps a Callers
    /// tree's rows from passing for a Callees tree's.
    func rootIdentifier(at index: Int) -> String {
        "crossReference|\(direction.rawValue)|\(index)"
    }

    /// What tells a row apart from the others under the same parent.
    static func key(of item: FindCrossReferenceRow.Item) -> String {
        switch item {
        case .function(let function):
            "function|\(function.imagePath)|\(String(function.address, radix: 16))"
        case .target(let target):
            switch target {
            case .function(let function): "function|\(function.imagePath)|\(String(function.address, radix: 16))"
            case .importedSymbol(let name): "imported|\(name)"
            case .selector(let name, let receiverClassName): "selector|\(name)|\(receiverClassName ?? "")"
            case .type(let name, let object): "type|\(name)|\(object.map { "\($0.kind)|\($0.imagePath)" } ?? "")"
            case .indirect(let tableOffset, let constant): "indirect|\(tableOffset.map(String.init) ?? "")|\(constant.map(String.init) ?? "")"
            case .unrecognizedCode(let address): "code|\(String(address, radix: 16))"
            }
        case .image(let path):
            "image|\(path)"
        case .loading:
            "~loading"
        case .failure:
            "~failure"
        }
    }

    // MARK: - Grouping

    /// A level of the tree out of what the engine found: one row per caller,
    /// per callee, or per image with its functions under it.
    static func rows(for references: [RuntimeCrossReference], direction: FindCrossReferenceDirection) -> [LoadedRow] {
        switch direction {
        case .callers:
            return grouped(references, by: \.referencingFunction)
                .map { function, references in LoadedRow(row: row(for: .function(function), references: references, direction: direction)) }
                .sorted(by: titleOrder)
        case .callees:
            // In the order the function makes them, as its body reads.
            var order: [String] = []
            var referencesByKey: [String: [RuntimeCrossReference]] = [:]
            var itemsByKey: [String: FindCrossReferenceRow.Item] = [:]
            for reference in references {
                let item: FindCrossReferenceRow.Item
                if case .function(let function) = reference.target {
                    item = .function(function)
                } else {
                    item = .target(reference.target)
                }
                let key = key(of: item)
                if referencesByKey[key] == nil {
                    order.append(key)
                    itemsByKey[key] = item
                }
                referencesByKey[key, default: []].append(reference)
            }
            return order.compactMap { key in
                guard let item = itemsByKey[key], let references = referencesByKey[key] else { return nil }
                return LoadedRow(row: row(for: item, references: references, direction: direction))
            }
        case .typeReferences:
            let referencesByImage = Dictionary(grouping: references, by: \.referencingFunction.imagePath)
            return referencesByImage
                .map { imagePath, references in
                    let functionRows = grouped(references, by: \.referencingFunction)
                        .map { function, references in LoadedRow(row: row(for: .function(function), references: references, direction: direction)) }
                        .sorted(by: titleOrder)
                    return LoadedRow(
                        row: FindCrossReferenceRow(item: .image(path: imagePath), direction: direction, referenceCount: references.count, precision: surestPrecision(of: references)),
                        children: functionRows
                    )
                }
                .sorted(by: titleOrder)
        }
    }

    private static func row(for item: FindCrossReferenceRow.Item, references: [RuntimeCrossReference], direction: FindCrossReferenceDirection) -> FindCrossReferenceRow {
        FindCrossReferenceRow(
            item: item,
            direction: direction,
            referenceCount: references.count,
            precision: surestPrecision(of: references),
            isRuntimeHelperCall: !references.isEmpty && references.allSatisfy(\.isRuntimeHelperCall)
        )
    }

    /// The references by function, a function's in the order they came.
    private static func grouped(_ references: [RuntimeCrossReference], by function: (RuntimeCrossReference) -> RuntimeFunctionReference) -> [(RuntimeFunctionReference, [RuntimeCrossReference])] {
        var order: [RuntimeFunctionReference] = []
        var referencesByFunction: [RuntimeFunctionReference: [RuntimeCrossReference]] = [:]
        for reference in references {
            let referencingFunction = function(reference)
            if referencesByFunction[referencingFunction] == nil {
                order.append(referencingFunction)
            }
            referencesByFunction[referencingFunction, default: []].append(reference)
        }
        return order.map { ($0, referencesByFunction[$0] ?? []) }
    }

    /// Exact when any one is: the row then certainly stands for the subject.
    static func surestPrecision(of references: [RuntimeCrossReference]) -> RuntimeCrossReferencePrecision? {
        let precisions = Set(references.map(\.precision))
        if precisions.contains(.exact) { return .exact }
        if precisions.contains(.matchedBySelector) { return .matchedBySelector }
        if precisions.contains(.candidate) { return .candidate }
        return nil
    }

    /// Xcode's order: `-[NSString compare:]` on the titles.
    private static func titleOrder(_ left: LoadedRow, _ right: LoadedRow) -> Bool {
        (left.row.title as NSString).compare(right.row.title) == .orderedAscending
    }
}
