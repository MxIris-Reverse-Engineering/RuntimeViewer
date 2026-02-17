import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingConfigurationViewController: AppKitViewController<ExportingConfigurationViewModel> {
    // MARK: - Relays

    private let cancelRelay = PublishRelay<Void>()
    private let backRelay = PublishRelay<Void>()
    private let exportRelay = PublishRelay<Void>()
    private let objcFormatRelay = PublishRelay<Int>()
    private let swiftFormatRelay = PublishRelay<Int>()

    // MARK: - UI

    private let summaryLabel = Label()

    private let objcSectionView = NSView()
    private let objcSingleFileRadio = NSButton()
    private let objcDirectoryRadio = NSButton()

    private let swiftSectionView = NSView()
    private let swiftSingleFileRadio = NSButton()
    private let swiftDirectoryRadio = NSButton()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        let headerLabel = Label("Export Format").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 13)
            $0.textColor = .secondaryLabelColor
        }

        // ObjC section
        let objcTitleLabel = Label("Objective-C:").then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        objcSingleFileRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Single File (.h)"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .on
            $0.target = self
            $0.action = #selector(objcFormatChanged(_:))
            $0.tag = 0
        }

        let objcSingleDesc = Label("Combine all ObjC interfaces into one .h file").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        objcDirectoryRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .off
            $0.target = self
            $0.action = #selector(objcFormatChanged(_:))
            $0.tag = 1
        }

        let objcDirDesc = Label("Individual .h files in ObjCHeaders/ subdirectory").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        let objcStack = VStackView(alignment: .leading, spacing: 6) {
            objcTitleLabel
            VStackView(alignment: .leading, spacing: 2) {
                objcSingleFileRadio
                objcSingleDesc
            }
            VStackView(alignment: .leading, spacing: 2) {
                objcDirectoryRadio
                objcDirDesc
            }
        }

        // Swift section
        let swiftTitleLabel = Label("Swift:").then {
            $0.font = .systemFont(ofSize: 13, weight: .medium)
        }

        swiftSingleFileRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Single File (.swiftinterface)"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .on
            $0.target = self
            $0.action = #selector(swiftFormatChanged(_:))
            $0.tag = 0
        }

        let swiftSingleDesc = Label("Combine all Swift interfaces into one .swiftinterface file").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        swiftDirectoryRadio.do {
            $0.setButtonType(.radio)
            $0.title = "Directory Structure"
            $0.font = .systemFont(ofSize: 13)
            $0.state = .off
            $0.target = self
            $0.action = #selector(swiftFormatChanged(_:))
            $0.tag = 1
        }

        let swiftDirDesc = Label("Individual files in SwiftInterfaces/ subdirectory").then {
            $0.font = .systemFont(ofSize: 11)
            $0.textColor = .tertiaryLabelColor
        }

        let swiftStack = VStackView(alignment: .leading, spacing: 6) {
            swiftTitleLabel
            VStackView(alignment: .leading, spacing: 2) {
                swiftSingleFileRadio
                swiftSingleDesc
            }
            VStackView(alignment: .leading, spacing: 2) {
                swiftDirectoryRadio
                swiftDirDesc
            }
        }

        objcSectionView.hierarchy { objcStack }
        objcStack.snp.makeConstraints { $0.edges.equalToSuperview() }

        swiftSectionView.hierarchy { swiftStack }
        swiftStack.snp.makeConstraints { $0.edges.equalToSuperview() }

        let contentStack = VStackView(alignment: .leading, spacing: 16) {
            headerLabel
            summaryLabel
            objcSectionView
            swiftSectionView
        }

        let backButton = PushButton().then {
            $0.title = "Back"
            $0.target = self
            $0.action = #selector(backClicked)
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        let exportButton = PushButton().then {
            $0.title = "Export\u{2026}"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(exportClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            backButton
            cancelButton
            exportButton
        }

        view.hierarchy {
            contentStack
            buttonStack
        }

        contentStack.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview().inset(20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelRelay.accept(())
    }

    @objc private func backClicked() {
        backRelay.accept(())
    }

    @objc private func exportClicked() {
        exportRelay.accept(())
    }

    @objc private func objcFormatChanged(_ sender: NSButton) {
        objcSingleFileRadio.state = sender.tag == 0 ? .on : .off
        objcDirectoryRadio.state = sender.tag == 1 ? .on : .off
        objcFormatRelay.accept(sender.tag)
    }

    @objc private func swiftFormatChanged(_ sender: NSButton) {
        swiftSingleFileRadio.state = sender.tag == 0 ? .on : .off
        swiftDirectoryRadio.state = sender.tag == 1 ? .on : .off
        swiftFormatRelay.accept(sender.tag)
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ExportingConfigurationViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingConfigurationViewModel.Input(
            cancelClick: cancelRelay.asSignal(),
            backClick: backRelay.asSignal(),
            exportClick: exportRelay.asSignal(),
            objcFormatSelected: objcFormatRelay.asSignal(),
            swiftFormatSelected: swiftFormatRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.hasObjC.driveOnNext { [weak self] hasObjC in
            guard let self else { return }
            objcSectionView.isHidden = !hasObjC
        }
        .disposed(by: rx.disposeBag)

        output.hasSwift.driveOnNext { [weak self] hasSwift in
            guard let self else { return }
            swiftSectionView.isHidden = !hasSwift
        }
        .disposed(by: rx.disposeBag)

        Driver.combineLatest(output.objcCount, output.swiftCount, output.imageName)
            .driveOnNext { [weak self] objcCount, swiftCount, imageName in
                guard let self else { return }
                var parts: [String] = ["Image: \(imageName)"]
                if objcCount > 0 { parts.append("\(objcCount) ObjC") }
                if swiftCount > 0 { parts.append("\(swiftCount) Swift") }
                summaryLabel.stringValue = parts.joined(separator: " · ")
            }
            .disposed(by: rx.disposeBag)
    }
}
