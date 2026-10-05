import AppKit
import RuntimeViewerUI
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import SFSymbols
import SnapKit

/// A row of the Report navigator, laid out like Xcode's `DVTTableCellViewOneLine` in its Report
/// navigator: a 16-point icon at the leading edge, the title 19 points in, the secondary text right
/// after the title, and a 16-point status mark at the trailing edge — the small spinner while the
/// work runs (`IDELogNavigatorStatusView`), an issue mark once it failed.
final class ReportCellView: TableCellView {
    private let iconImageView = ImageView()

    private let titleLabel = Label()

    private let detailLabel = Label()

    private let progressIndicator = NSProgressIndicator()

    private let issueImageView = ImageView()

    private static let issueImage = SFSymbols(systemName: .xmarkOctagonFill).nsuiImgae

    /// What the cell shows now; `nil` until the first appearance after a bind. A running row's
    /// detail changes many times a second while its icon, title, tooltip and status stay as they
    /// are, so each part is set only when it differs — as it was when each part had a stream of
    /// its own.
    private var shownAppearance: ReportCellViewModel.Appearance?

    override func setup() {
        super.setup()

        hierarchy {
            iconImageView
            titleLabel
            detailLabel
            progressIndicator
            issueImageView
        }

        iconImageView.snp.makeConstraints { make in
            make.leading.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }

        titleLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().offset(19)
            make.centerY.equalToSuperview()
        }

        detailLabel.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(2)
            make.centerY.equalToSuperview()
            make.trailing.lessThanOrEqualTo(progressIndicator.snp.leading).offset(-4)
        }

        progressIndicator.snp.makeConstraints { make in
            make.trailing.equalToSuperview()
            make.centerY.equalToSuperview()
            make.size.equalTo(16)
        }

        issueImageView.snp.makeConstraints { make in
            make.edges.equalTo(progressIndicator)
        }

        iconImageView.do {
            $0.imageScaling = .scaleProportionallyDown
            $0.contentTintColor = .secondaryLabelColor
        }

        titleLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .labelColor
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            // The title gives way only once the secondary text has nothing left to give.
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultHigh - 1, for: .horizontal)
        }

        detailLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 1
            $0.lineBreakMode = .byTruncatingTail
            $0.setContentHuggingPriority(.defaultLow, for: .horizontal)
            $0.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        progressIndicator.do {
            $0.style = .spinning
            $0.controlSize = .small
            $0.isIndeterminate = true
            $0.isDisplayedWhenStopped = false
        }

        issueImageView.do {
            $0.image = Self.issueImage
            $0.imageScaling = .scaleProportionallyDown
            $0.contentTintColor = .systemRed
            $0.isHidden = true
        }
    }

    func bind(to cellViewModel: ReportCellViewModel) {
        rx.disposeBag = DisposeBag()
        shownAppearance = nil

        cellViewModel.$appearance.asDriver().driveOnNext { [weak self] appearance in
            guard let self else { return }
            apply(appearance)
        }
        .disposed(by: rx.disposeBag)
    }

    private func apply(_ appearance: ReportCellViewModel.Appearance) {
        let previousAppearance = shownAppearance
        shownAppearance = appearance

        func differs<Value: Equatable>(_ part: KeyPath<ReportCellViewModel.Appearance, Value>) -> Bool {
            guard let previousAppearance else { return true }
            return previousAppearance[keyPath: part] != appearance[keyPath: part]
        }

        if differs(\.icon) {
            iconImageView.image = appearance.icon
        }
        if differs(\.title) {
            titleLabel.stringValue = appearance.title
        }
        if differs(\.detail) {
            detailLabel.stringValue = appearance.detail
        }
        if differs(\.toolTip) {
            toolTip = appearance.toolTip
        }
        if differs(\.status) {
            show(appearance.status)
        }
    }

    private func show(_ status: ReportRowStatus) {
        switch status {
        case .none:
            progressIndicator.stopAnimation(nil)
            issueImageView.isHidden = true
            issueImageView.toolTip = nil
        case .running:
            progressIndicator.startAnimation(nil)
            issueImageView.isHidden = true
            issueImageView.toolTip = nil
        case .failed(let message):
            progressIndicator.stopAnimation(nil)
            issueImageView.isHidden = false
            issueImageView.toolTip = message
        }
    }
}
