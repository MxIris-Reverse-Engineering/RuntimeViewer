import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import SnapKit

/// The naming word cloud's Compound Words sheet: the words counted as one,
/// a field to add one, and buttons to remove the selected ones, restore the
/// presets and close.
final class NamingCompoundWordsViewController: BaseViewController<NamingCompoundWordsViewModel> {
    // MARK: - Views

    private let titleLabel = Label("Compound Words").then {
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
    }

    private let explanationLabel = Label("Words that always run together are counted as one: NSTableViewDataSource ends in DataSource, not Source.").then {
        $0.textColor = .secondaryLabelColor
        $0.maximumNumberOfLines = 0
        $0.lineBreakMode = .byWordWrapping
    }

    private let (scrollView, tableView): (ScrollView, SingleColumnTableView) = SingleColumnTableView.scrollableTableView()

    private let wordField = NSTextField().then {
        $0.placeholderString = "Add a word, such as VisualProvider"
    }

    /// The default button: Return in the field adds the word.
    private let addButton = PushButton().then {
        $0.title = "Add"
        $0.keyEquivalent = "\r"
    }

    private let removeButton = PushButton().then {
        $0.title = "Remove"
    }

    private let restoreButton = PushButton().then {
        $0.title = "Restore Presets"
    }

    /// Escape closes the sheet.
    private let doneButton = PushButton().then {
        $0.title = "Done"
        $0.keyEquivalent = "\u{1b}"
    }

    private let refusalLabel = Label().then {
        $0.textColor = .systemRed
        $0.maximumNumberOfLines = 0
        $0.lineBreakMode = .byWordWrapping
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        tableView.allowsMultipleSelection = true

        containerView.hierarchy {
            titleLabel
            explanationLabel
            scrollView
            wordField
            addButton
            refusalLabel
            removeButton
            restoreButton
            doneButton
        }

        titleLabel.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(16)
        }
        explanationLabel.snp.makeConstraints { make in
            make.top.equalTo(titleLabel.snp.bottom).offset(6)
            make.leading.trailing.equalToSuperview().inset(16)
        }
        scrollView.snp.makeConstraints { make in
            make.top.equalTo(explanationLabel.snp.bottom).offset(10)
            make.leading.trailing.equalToSuperview().inset(16)
            make.height.greaterThanOrEqualTo(220)
        }
        wordField.snp.makeConstraints { make in
            make.top.equalTo(scrollView.snp.bottom).offset(10)
            make.leading.equalToSuperview().inset(16)
        }
        addButton.snp.makeConstraints { make in
            make.centerY.equalTo(wordField)
            make.leading.equalTo(wordField.snp.trailing).offset(8)
            make.trailing.equalToSuperview().inset(16)
        }
        refusalLabel.snp.makeConstraints { make in
            make.top.equalTo(wordField.snp.bottom).offset(6)
            make.leading.trailing.equalToSuperview().inset(16)
        }
        removeButton.snp.makeConstraints { make in
            make.top.equalTo(refusalLabel.snp.bottom).offset(12)
            make.leading.equalToSuperview().inset(16)
            make.bottom.equalToSuperview().inset(16)
        }
        restoreButton.snp.makeConstraints { make in
            make.centerY.equalTo(removeButton)
            make.leading.equalTo(removeButton.snp.trailing).offset(8)
        }
        doneButton.snp.makeConstraints { make in
            make.centerY.equalTo(removeButton)
            make.trailing.equalToSuperview().inset(16)
        }
        view.snp.makeConstraints { make in
            make.width.equalTo(420)
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: NamingCompoundWordsViewModel) {
        super.setupBindings(for: viewModel)

        let addedWords = addButton.rx.click.asSignal()
            .compactMap { [weak self] () -> String? in
                guard let self else { return nil }
                let word = wordField.stringValue
                wordField.stringValue = ""
                return word.isEmpty ? nil : word
            }

        let removedRows = removeButton.rx.click.asSignal()
            .compactMap { [weak self] () -> [Int]? in
                guard let self else { return nil }
                return Array(tableView.selectedRowIndexes)
            }

        let output = viewModel.transform(.init(
            addWord: addedWords,
            removeRows: removedRows,
            restorePresets: restoreButton.rx.click.asSignal(),
            done: doneButton.rx.click.asSignal()
        ))

        output.rows
            .map { $0.map(DifferentiableBox.init) }
            .drive(tableView.rx.items) { (tableView: NSTableView, _: NSTableColumn?, _: Int, box: DifferentiableBox<NamingCompoundWordsViewModel.Row>) -> NSView? in
                let cellView = tableView.box.makeView(ofClass: CompoundWordCellView.self)
                cellView.configure(with: box.model)
                return cellView
            }
            .disposed(by: rx.disposeBag)

        output.refusal
            .emit(to: refusalLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        addButton.rx.click.asSignal()
            .map { "" }
            .emit(to: refusalLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)
    }
}

extension NamingCompoundWordsViewController {
    fileprivate final class CompoundWordCellView: TableCellView {
        private let wordLabel = Label()

        private let detailLabel = Label().then {
            $0.textColor = .secondaryLabelColor
            $0.alignment = .right
        }

        override func setup() {
            super.setup()
            hierarchy {
                wordLabel
                detailLabel
            }
            wordLabel.snp.makeConstraints { make in
                make.leading.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
            detailLabel.snp.makeConstraints { make in
                make.leading.greaterThanOrEqualTo(wordLabel.snp.trailing).offset(8)
                make.trailing.equalToSuperview().inset(6)
                make.centerY.equalToSuperview()
            }
        }

        /// Static: a row's word and whether it is a preset never change.
        func configure(with row: NamingCompoundWordsViewModel.Row) {
            wordLabel.stringValue = row.word
            detailLabel.stringValue = row.detail
        }
    }
}
