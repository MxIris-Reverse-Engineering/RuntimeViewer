import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// A click on a list row: the row's model, and where the click's modifiers
/// send it — ⌥ the next editor pane, ⇧⌥ a new tab, none the focused tab, as in
/// the sidebar and the Find navigator.
struct ListRowClick<Model> {
    let model: Model
    let destination: SelectionRoute.Destination

    init(model: Model, destination: SelectionRoute.Destination) {
        self.model = model
        self.destination = destination
    }

    /// The click with the modifiers held as it happens.
    init(model: Model) {
        self.init(model: model, destination: SelectionRoute.Destination(listClickModifierFlags: NSApp.currentEvent?.modifierFlags ?? []))
    }
}

extension Reactive where Base: NSTableView {
    /// Every click on a row bound through `rx.items`, as a `ListRowClick`.
    func rowClicks<Model>(of modelType: Model.Type) -> Signal<ListRowClick<Model>> {
        itemClicked()
            .compactMap { [weak tableView = base] index -> ListRowClick<Model>? in
                guard let tableView, index.row >= 0, index.row < tableView.numberOfRows,
                      let model: Model = try? tableView.rx.model(at: index.row)
                else { return nil }
                return ListRowClick(model: model)
            }
            .asSignal(onErrorSignalWith: .empty())
    }
}

extension RuntimeObjectAction {
    /// A context menu's entries for `runtimeObject`: every command it offers,
    /// each reported through `relay` when chosen.
    static func contextMenuItems(for runtimeObject: RuntimeObject, reportingTo relay: PublishRelay<RuntimeObjectActionRequest>) -> [ContextMenuItem] {
        actions(for: runtimeObject).map { action in
            ContextMenuItem(action) {
                relay.accept(RuntimeObjectActionRequest(action: action, runtimeObject: runtimeObject))
            }
        }
    }

    /// The command a modified click on a row showing `runtimeObject` stands
    /// for, or `nil` for a plain click — which each list handles its own way —
    /// and for a row with no object.
    static func request(for runtimeObject: RuntimeObject?, clickedTowards destination: SelectionRoute.Destination) -> RuntimeObjectActionRequest? {
        guard let runtimeObject, let action = RuntimeObjectAction(opening: destination) else { return nil }
        return RuntimeObjectActionRequest(action: action, runtimeObject: runtimeObject)
    }
}
