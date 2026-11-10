import Foundation
import Dependencies
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerUI

/// One engine's work as the Report navigator lists it: the group it goes under, the name and the
/// icon the group shows and the work itself.
///
/// A document that borrows shared cache images holds the work of every engine it borrows from
/// besides its own engine's, and its Report lists each engine's work in a group of its own — the
/// document's engine first — with the same three kinds of work inside as an engine's own Report
/// has. A document that borrows nothing has one group, and its Report shows the kinds of work at
/// the top, as it always did.
@MainActor
struct ReportGroupWork {
    let group: ReportEngineGroup

    /// What the group's row says: the engine's name.
    let engineName: String

    /// What the group's row shows before the name: the engine's icon as the runtime source picker
    /// lists it. Resolved once, with the session: the row is built again each time any work under
    /// it moves on, and an icon resolved each time is a new image each time, which the row would
    /// take for a change and set again. None off macOS, where nothing resolves an engine's icon.
    let engineIcon: NSUIImage?

    let backgroundWork: RuntimeEngineBackgroundWork

    /// The work `session` holds, the engine's own first, then that of each engine it borrows
    /// from; none while it holds none.
    static func groups(of session: RuntimeEngineSession) -> [ReportGroupWork] {
        guard let ownWork = session.backgroundWork else { return [] }
        let ownGroup = ReportGroupWork(group: .own, engine: session.engine, backgroundWork: ownWork)
        return [ownGroup] + session.borrowedBackgroundWorks.map { borrowedWork in
            ReportGroupWork(group: .owner(ObjectIdentifier(borrowedWork.engine)), engine: borrowedWork.engine, backgroundWork: borrowedWork)
        }
    }

    private init(group: ReportEngineGroup, engine: RuntimeEngine, backgroundWork: RuntimeEngineBackgroundWork) {
        self.group = group
        self.engineName = engine.source.description
        self.engineIcon = Self.icon(for: engine)
        self.backgroundWork = backgroundWork
    }

    private static func icon(for engine: RuntimeEngine) -> NSUIImage? {
        #if os(macOS)
        @Dependency(\.runtimeEngineIconProvider) var runtimeEngineIconProvider
        return runtimeEngineIconProvider.icon(for: engine)
        #else
        return nil
        #endif
    }

    /// `node`, built as the engine's own Report has it, as this group lists it.
    func listed(_ node: ReportNode) -> ReportNode {
        switch group {
        case .own:
            node
        case .owner(let owner):
            node.borrowed(from: owner)
        }
    }

    /// The work a row of `session`'s Report stands for, and the row as that work's own Report knows
    /// it: what a command on the row acts on. `nil` while the session holds no work, and for a row
    /// of an engine the session no longer borrows from.
    static func target(of identifier: ReportNodeIdentifier, in session: RuntimeEngineSession) -> (backgroundWork: RuntimeEngineBackgroundWork, identifier: ReportNodeIdentifier)? {
        if case .borrowed(let owner, let borrowedIdentifier) = identifier {
            guard let borrowedWork = session.borrowedBackgroundWorks.first(where: { ObjectIdentifier($0.engine) == owner }) else { return nil }
            return (borrowedWork, borrowedIdentifier)
        }
        guard let ownWork = session.backgroundWork else { return nil }
        return (ownWork, identifier)
    }
}

/// The Report page's tree builders and group rows, one of each per group, kept across rebuilds so
/// every row keeps its cell ViewModel; a group the document no longer lists lets go of both.
@MainActor
final class ReportGroupTreeBuilders {
    private var treeBuilders: [ReportEngineGroup: ReportTreeBuilder] = [:]

    private var groupCellViewModels: [ReportEngineGroup: ReportCellViewModel] = [:]

    /// Lets go of the builders and rows of every group but `groups`.
    func keepOnly(_ groups: [ReportEngineGroup]) {
        let keptGroups = Set(groups)
        treeBuilders = treeBuilders.filter { keptGroups.contains($0.key) }
        groupCellViewModels = groupCellViewModels.filter { keptGroups.contains($0.key) }
    }

    func treeBuilder(for group: ReportEngineGroup) -> ReportTreeBuilder {
        if let treeBuilder = treeBuilders[group] {
            return treeBuilder
        }
        let treeBuilder = ReportTreeBuilder()
        treeBuilders[group] = treeBuilder
        return treeBuilder
    }

    /// The row of `groupWork`'s group, above `children`.
    func groupNode(for groupWork: ReportGroupWork, children: [ReportNode]) -> ReportNode {
        let identifier = ReportNodeIdentifier.engineGroup(groupWork.group)
        let cellViewModel = groupCellViewModels[groupWork.group] ?? ReportCellViewModel(identifier: identifier)
        groupCellViewModels[groupWork.group] = cellViewModel
        let toolTip: String? = switch groupWork.group {
        case .own:
            nil
        case .owner:
            "The shared cache images \(groupWork.engineName) keeps for this source: its work for them is shared with every window that shows them."
        }
        cellViewModel.update(icon: groupWork.engineIcon, title: groupWork.engineName, toolTip: toolTip)
        return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
    }
}
