import AppKit
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

/// The popover a sidebar row's `Private` tag opens: the row's name, then each private declaration
/// it runs through, with its discriminator and recovered source file.
final class PrivateDeclarationViewController: BaseViewController<PrivateDeclarationViewModel> {
    // MARK: - Views

    // Configured where they are declared: the bindings can assign text before
    // the view loads, and a label copies its text into its tooltip unless told
    // not to first.

    private let titleLabel = Label().then {
        $0.syncStringValueToolTip = false
        $0.font = .systemFont(ofSize: 13, weight: .semibold)
        $0.stringValue = "Private Declaration"
    }

    private let displayNameLabel = Label().then {
        PrivateDeclarationViewController.configureWrapping($0, width: PrivateDeclarationViewController.contentWidth)
        $0.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        $0.textColor = .secondaryLabelColor
        $0.isSelectable = true
    }

    private let declarationsStackView = VStackView(alignment: .leading, spacing: 12) {}

    private let explanationLabel = Label().then {
        PrivateDeclarationViewController.configureWrapping($0, width: PrivateDeclarationViewController.contentWidth)
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
        $0.stringValue = "A discriminator is the MD5 of its module's and source file's names. The file is found by hashing candidates against it — file names known from open-source projects, and names made from this image's — and Unknown means none of them matched."
    }

    private lazy var contentStackView = VStackView(alignment: .leading, spacing: 10) {
        titleLabel
        displayNameLabel
        declarationsStackView
        explanationLabel
    }

    private static let contentWidth: CGFloat = 380

    private static let rowTitleWidth: CGFloat = 84

    private static let rowSpacing: CGFloat = 8

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        containerView.hierarchy {
            contentStackView
        }

        contentStackView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(14)
            make.width.equalTo(Self.contentWidth)
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: PrivateDeclarationViewModel) {
        super.setupBindings(for: viewModel)

        let output = viewModel.transform(PrivateDeclarationViewModel.Input())

        output.displayName.drive(displayNameLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.declarations.driveOnNext { [weak self] declarations in
            guard let self else { return }
            showDeclarations(declarations)
        }
        .disposed(by: rx.disposeBag)
    }

    // MARK: - Declarations

    private func showDeclarations(_ declarations: [PrivateDeclarationViewModel.Declaration]) {
        declarationsStackView.setViews(declarations.map { makeDeclarationView(for: $0) }, in: .leading)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func makeDeclarationView(for declaration: PrivateDeclarationViewModel.Declaration) -> NSView {
        let nameLabel = Label()
        nameLabel.syncStringValueToolTip = false
        nameLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        nameLabel.stringValue = declaration.name ?? "Unnamed Declaration"

        let discriminatorLabel = makeValueLabel()
        discriminatorLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        discriminatorLabel.stringValue = declaration.discriminator

        let sourceFileLabel = makeValueLabel()
        sourceFileLabel.attributedStringValue = Self.sourceFileText(for: declaration.sourceFile)

        return VStackView(alignment: .leading, spacing: 4) {
            nameLabel
            makeRow(title: "Discriminator", valueLabel: discriminatorLabel)
            makeRow(title: "Source File", valueLabel: sourceFileLabel)
        }
    }

    private func makeRow(title: String, valueLabel: Label) -> NSView {
        let titleLabel = Label()
        titleLabel.syncStringValueToolTip = false
        titleLabel.font = .systemFont(ofSize: 11)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.stringValue = title
        titleLabel.snp.makeConstraints { make in
            make.width.equalTo(Self.rowTitleWidth)
        }
        return HStackView(alignment: .firstBaseline, spacing: Self.rowSpacing) {
            titleLabel
            valueLabel
        }
    }

    private func makeValueLabel() -> Label {
        let valueLabel = Label()
        Self.configureWrapping(valueLabel, width: Self.contentWidth - Self.rowTitleWidth - Self.rowSpacing)
        valueLabel.font = .systemFont(ofSize: 11)
        valueLabel.isSelectable = true
        return valueLabel
    }

    private static func sourceFileText(for sourceFile: PrivateDeclarationViewModel.SourceFile) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: 11)
        switch sourceFile {
        case .pending:
            return NSAttributedString(string: "", attributes: [.font: font])
        case .recovering:
            return NSAttributedString(string: "Recovering…", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        case .recovered(let fileName, let moduleName, let isSynthesized):
            let text = NSMutableAttributedString(string: fileName, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
            let detail = isSynthesized ? "  in \(moduleName), synthesized" : "  in \(moduleName)"
            text.append(NSAttributedString(string: detail, attributes: [.font: font, .foregroundColor: NSColor.secondaryLabelColor]))
            return text
        case .unrecovered:
            return NSAttributedString(string: "Unknown", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor])
        }
    }

    /// Wraps at any character, `width` points wide: the names and
    /// discriminators are long runs without spaces.
    private static func configureWrapping(_ label: Label, width: CGFloat) {
        label.syncStringValueToolTip = false
        label.maximumNumberOfLines = 0
        label.lineBreakMode = .byCharWrapping
        label.preferredMaxLayoutWidth = width
    }
}
