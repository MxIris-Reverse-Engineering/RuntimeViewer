import AppKit
import RuntimeViewerCore
import RuntimeViewerApplication

class SidebarRootOutlineViewDataSource: NSObject, NSOutlineViewDataSource {
    weak var viewModel: SidebarRootViewModel?

    init(viewModel: SidebarRootViewModel) {
        self.viewModel = viewModel
        super.init()
    }

    func outlineView(_ outlineView: NSOutlineView, itemForPersistentObject object: Any) -> Any? {
        guard let viewModel else { return nil }
        guard let path = object as? String else {
            print("Invalid persistent object:", object)
            return nil
        }
        let item = viewModel.allNodes[path]
        return item
    }

    func outlineView(_ outlineView: NSOutlineView, persistentObjectForItem item: Any?) -> Any? {
        guard let item = item as? SidebarRootCellViewModel else { return nil }
        let returnObject = item.node.parent != nil ? item.node.absolutePath : item.node.name
        return returnObject
    }
}
