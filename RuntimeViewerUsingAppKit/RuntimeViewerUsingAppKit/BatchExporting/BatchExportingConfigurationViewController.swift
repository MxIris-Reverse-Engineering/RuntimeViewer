import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI

final class BatchExportingConfigurationViewController: BaseViewController<BatchExportingConfigurationViewModel>, ExportingStepViewController {

    private let summaryLabel = Label()

    private let objcSingleFileRadio = RadioButton()
    private let objcDirectoryRadio = RadioButton()

    private let swiftSingleFileRadio = RadioButton()
    private let swiftDirectoryRadio = RadioButton()

    private let cPlusPlusSingleFileRadio = RadioButton()
    private let cPlusPlusDirectoryRadio = RadioButton()

    private let includeMetadataCheckbox = CheckboxButton()

    private let objcTitleLabel = Label("Objective-C:").then {
        $0.font = .systemFont(ofSize: 13, weight: .medium)
    }

    private let objcSingleDesc = Label("Combine all ObjC interfaces into one .h file per image").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let objcDirDesc = Label("Individual .h files in each image's ObjCHeaders/ subdirectory").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let swiftTitleLabel = Label("Swift:").then {
        $0.font = .systemFont(ofSize: 13, weight: .medium)
    }

    private let swiftSingleDesc = Label("Combine all Swift interfaces into one .swiftinterface file per image").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let swiftDirDesc = Label("Individual files in each image's SwiftInterfaces/ subdirectory").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let cPlusPlusTitleLabel = Label("C++:").then {
        $0.font = .systemFont(ofSize: 13, weight: .medium)
    }

    private let cPlusPlusSingleFileDescriptionLabel = Label("Combine all C++ interfaces into one .hpp file per image").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let cPlusPlusDirectoryDescriptionLabel = Label("Individual .hpp files in each image's CPlusPlusHeaders/ subdirectory").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    private let metadataDesc = Label("Write README.md with RuntimeViewer, module, date, license, and dump option details").then {
        $0.font = .systemFont(ofSize: 11)
        $0.textColor = .tertiaryLabelColor
    }

    /// The page scrolls once its groups are taller than the sheet: the Objective-C, Swift and C++ groups
    /// together do not fit.
    private let pageScrollView = ScrollView()

    private lazy var contentStack = VStackView(alignment: .leading, spacing: 16) {
        summaryLabel
        objcStack
        swiftStack
        cPlusPlusStack
        metadataStack
    }

    private lazy var objcStack = VStackView(alignment: .leading, spacing: 12) {
        objcTitleLabel
        VStackView(alignment: .leading, spacing: 4) {
            objcSingleFileRadio
            objcSingleDesc
        }
        VStackView(alignment: .leading, spacing: 4) {
            objcDirectoryRadio
            objcDirDesc
        }
    }

    private lazy var swiftStack = VStackView(alignment: .leading, spacing: 12) {
        swiftTitleLabel
        VStackView(alignment: .leading, spacing: 4) {
            swiftSingleFileRadio
            swiftSingleDesc
        }
        VStackView(alignment: .leading, spacing: 4) {
            swiftDirectoryRadio
            swiftDirDesc
        }
    }

    private lazy var cPlusPlusStack = VStackView(alignment: .leading, spacing: 12) {
        cPlusPlusTitleLabel
        VStackView(alignment: .leading, spacing: 4) {
            cPlusPlusSingleFileRadio
            cPlusPlusSingleFileDescriptionLabel
        }
        VStackView(alignment: .leading, spacing: 4) {
            cPlusPlusDirectoryRadio
            cPlusPlusDirectoryDescriptionLabel
        }
    }

    private lazy var metadataStack = VStackView(alignment: .leading, spacing: 4) {
        includeMetadataCheckbox
        metadataDesc
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
            $0.maximumNumberOfLines = 0
        }

        objcSingleFileRadio.do {
            $0.title = "Single File (.h)"
            $0.font = .systemFont(ofSize: 13)
        }

        objcDirectoryRadio.do {
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
        }

        swiftSingleFileRadio.do {
            $0.title = "Single File (.swiftinterface)"
            $0.font = .systemFont(ofSize: 13)
        }

        swiftDirectoryRadio.do {
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
        }

        cPlusPlusSingleFileRadio.do {
            $0.title = "Single File (.hpp)"
            $0.font = .systemFont(ofSize: 13)
        }

        cPlusPlusDirectoryRadio.do {
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
        }

        includeMetadataCheckbox.do {
            $0.title = "Include README metadata"
            $0.font = .systemFont(ofSize: 13)
        }

        pageScrollView.do {
            $0.hasVerticalScroller = true
            $0.hasHorizontalScroller = false
            $0.autohidesScrollers = true
            $0.borderType = .noBorder
        }

        let documentView = DocumentView()
        documentView.hierarchy {
            contentStack
        }
        pageScrollView.documentView = documentView
        containerView.hierarchy {
            pageScrollView
        }

        pageScrollView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        documentView.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
            make.width.equalTo(pageScrollView.contentView)
        }

        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(20)
        }
    }

    override func setupBindings(for viewModel: BatchExportingConfigurationViewModel) {
        super.setupBindings(for: viewModel)

        let input = BatchExportingConfigurationViewModel.Input(
            objcFormatSelected: Signal.merge(
                objcSingleFileRadio.rx.click.asSignal().map { ExportFormat.singleFile.rawValue },
                objcDirectoryRadio.rx.click.asSignal().map { ExportFormat.directory.rawValue }
            ),
            swiftFormatSelected: Signal.merge(
                swiftSingleFileRadio.rx.click.asSignal().map { ExportFormat.singleFile.rawValue },
                swiftDirectoryRadio.rx.click.asSignal().map { ExportFormat.directory.rawValue }
            ),
            cPlusPlusFormatSelected: Signal.merge(
                cPlusPlusSingleFileRadio.rx.click.asSignal().map { ExportFormat.singleFile.rawValue },
                cPlusPlusDirectoryRadio.rx.click.asSignal().map { ExportFormat.directory.rawValue }
            ),
            includeMetadataSelected: includeMetadataCheckbox.rx.state.asSignal().map { $0 == .on }
        )

        let output = viewModel.transform(input)

        output.objcFormat.map { $0 == .singleFile }.drive(objcSingleFileRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.objcFormat.map { $0 == .directory }.drive(objcDirectoryRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.swiftFormat.map { $0 == .singleFile }.drive(swiftSingleFileRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.swiftFormat.map { $0 == .directory }.drive(swiftDirectoryRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.cPlusPlusFormat.map { $0 == .singleFile }.drive(cPlusPlusSingleFileRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.cPlusPlusFormat.map { $0 == .directory }.drive(cPlusPlusDirectoryRadio.rx.isCheck).disposed(by: rx.disposeBag)
        output.includeMetadata.drive(includeMetadataCheckbox.rx.isCheck).disposed(by: rx.disposeBag)

        output.summary.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)
    }
}

extension BatchExportingConfigurationViewController {
    /// The page's document view: laid out from the top down.
    private final class DocumentView: NSView {
        override var isFlipped: Bool { true }
    }
}
