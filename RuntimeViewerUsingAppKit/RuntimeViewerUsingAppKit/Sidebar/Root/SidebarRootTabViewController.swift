import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures

final class SidebarRootTabViewController: TabViewController {
    override var pageLayout: PageLayout { .underSegmentedControl }
}
