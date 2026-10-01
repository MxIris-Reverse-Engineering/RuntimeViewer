import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerUI

/// What one row of the Report navigator shows, laid out like Xcode's `DVTTableCellViewOneLine`:
/// an icon, the title, a secondary text right after it and a status mark at the trailing edge.
///
/// One instance per row for as long as the row exists. The Report ViewModel feeds it each time
/// the reports change and the cell observes it, so a row's progress updates in place — a reload
/// would not even reach the cell, since the outline's `reloadItem` does not ask for a new one.
public final class ReportCellViewModel: NSObject, @unchecked Sendable {
    public let identifier: ReportNodeIdentifier

    @RxObserved
    public private(set) var icon: NSUIImage?

    @RxObserved
    public private(set) var title: String = ""

    /// Right after the title, in the secondary color: progress, a count or a time.
    @RxObserved
    public private(set) var detail: String = ""

    @RxObserved
    public private(set) var status: ReportRowStatus = .none

    @RxObserved
    public private(set) var toolTip: String?

    /// Whether the row stands for work that can be withdrawn now.
    public private(set) var isCancellable = false

    /// Whether the row stands for work that has not ended: running, or queued to run. What the
    /// filter bar's clock keeps.
    public private(set) var isInProgress = false

    init(identifier: ReportNodeIdentifier) {
        self.identifier = identifier
        super.init()
    }

    /// Sets what the row shows, touching only the values that changed so the cell's bindings fire
    /// for real changes only.
    func update(icon: NSUIImage?, title: String, detail: String = "", status: ReportRowStatus = .none, toolTip: String? = nil, isCancellable: Bool = false, isInProgress: Bool = false) {
        if self.icon !== icon {
            self.icon = icon
        }
        if self.title != title {
            self.title = title
        }
        if self.detail != detail {
            self.detail = detail
        }
        if self.status != status {
            self.status = status
        }
        if self.toolTip != toolTip {
            self.toolTip = toolTip
        }
        self.isCancellable = isCancellable
        self.isInProgress = isInProgress
    }
}
