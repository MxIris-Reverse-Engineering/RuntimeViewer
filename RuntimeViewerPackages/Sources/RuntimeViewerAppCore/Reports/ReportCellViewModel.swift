import Foundation
import RuntimeViewerArchitectures

/// What one row of the Report navigator shows, laid out like Xcode's `DVTTableCellViewOneLine`:
/// an icon, the title, a secondary text right after it and a status mark at the trailing edge.
///
/// One instance per row for as long as the row exists. The Report ViewModel feeds it each time
/// the reports change and the cell observes it, so a row's progress updates in place — a reload
/// would not even reach the cell, since the outline's `reloadItem` does not ask for a new one.
public final class ReportCellViewModel: NSObject, @unchecked Sendable {
    public let identifier: ReportNodeIdentifier

    /// Everything the row shows, in one stream. The navigator keeps a row per indexed image and
    /// per corpus build — hundreds of them in a large batch — and every `@RxObserved` a cell binds
    /// costs a relay with a lock of its own for as long as the row exists (proposal
    /// 0005-cellvm-appearance-single-observed).
    public struct Appearance: Equatable {
        public var icon: NSUIImage?

        /// The colour the template `icon` is drawn in when the row has one of its own: an image's,
        /// after what the image is part of (`RuntimeImageKind.iconColor`). `nil` leaves the
        /// navigator's secondary label colour.
        public var iconColor: NSUIColor?

        public var title: String = ""

        /// Right after the title, in the secondary color: progress, a count or a time.
        public var detail: String = ""

        public var status: ReportRowStatus = .none

        public var toolTip: String?

        /// An Eject button at the trailing edge, as Finder gives a volume: the row of a kind of
        /// work whose results the engine's process keeps, which the user can have it drop. The
        /// status mark takes the same place, and the rows that have one never eject.
        public var showsEjectButton = false
    }

    @RxObserved
    public private(set) var appearance: Appearance = Appearance()

    /// Whether the row stands for work that can be withdrawn now.
    public private(set) var isCancellable = false

    /// Whether the row stands for work that has not ended: running, or queued to run. What the
    /// filter bar's clock keeps.
    public private(set) var isInProgress = false

    init(identifier: ReportNodeIdentifier) {
        self.identifier = identifier
        super.init()
    }

    /// Sets what the row shows. The appearance is published in one assignment and only when it
    /// changed, so the cell's binding fires once per real change.
    func update(icon: NSUIImage?, iconColor: NSUIColor? = nil, title: String, detail: String = "", status: ReportRowStatus = .none, toolTip: String? = nil, isCancellable: Bool = false, isInProgress: Bool = false, isEjectable: Bool = false) {
        let newAppearance = Appearance(icon: icon, iconColor: iconColor, title: title, detail: detail, status: status, toolTip: toolTip, showsEjectButton: isEjectable)
        if appearance != newAppearance {
            appearance = newAppearance
        }
        self.isCancellable = isCancellable
        self.isInProgress = isInProgress
    }
}
