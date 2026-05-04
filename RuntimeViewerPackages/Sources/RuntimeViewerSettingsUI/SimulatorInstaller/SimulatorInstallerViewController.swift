#if os(macOS)

import AppKit
import RuntimeViewerUI

final class SimulatorInstallerViewController: NSViewController, NSTextFieldDelegate {
    private let viewModel: SimulatorInstallerViewModel

    private let contentStack = NSStackView()
    private let currentVersionLabel = NSTextField(labelWithString: "")
    private let versionTextField = NSTextField()
    private let resetVersionButton = NSButton()
    private let downloadButton = NSButton()
    private let downloadProgressIndicator = NSProgressIndicator()
    private let downloadStatusLabel = NSTextField(labelWithString: "")
    private let artifactPopUpButton = NSPopUpButton()
    private let revealArtifactButton = NSButton()
    private let deleteArtifactButton = NSButton()
    private let simulatorPopUpButton = NSPopUpButton()
    private let refreshSimulatorsButton = NSButton()
    private let installButton = NSButton()
    private let installStatusLabel = NSTextField(labelWithString: "")

    init(viewModel: SimulatorInstallerViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        configureViews()
        buildLayout()

        viewModel.onChange = { [weak self] in
            self?.render()
        }
        viewModel.refresh()
        render()
    }

    private func configureViews() {
        contentStack.orientation = .vertical
        contentStack.spacing = 16
        contentStack.alignment = .width

        currentVersionLabel.stringValue = viewModel.currentVersion
        currentVersionLabel.textColor = .secondaryLabelColor

        versionTextField.stringValue = viewModel.version
        versionTextField.placeholderString = viewModel.currentVersion
        versionTextField.delegate = self
        versionTextField.controlSize = .large

        configureButton(resetVersionButton, title: "Reset", symbolName: "arrow.counterclockwise")
        resetVersionButton.target = self
        resetVersionButton.action = #selector(resetVersion)

        configureButton(downloadButton, title: "Download", symbolName: "arrow.down.circle")
        downloadButton.target = self
        downloadButton.action = #selector(downloadSelectedVersion)

        downloadProgressIndicator.style = .bar
        downloadProgressIndicator.isIndeterminate = false
        downloadProgressIndicator.minValue = 0
        downloadProgressIndicator.maxValue = 1

        configureStatusLabel(downloadStatusLabel)
        configureStatusLabel(installStatusLabel)

        artifactPopUpButton.target = self
        artifactPopUpButton.action = #selector(artifactSelectionChanged)

        configureButton(revealArtifactButton, title: "Reveal", symbolName: "folder")
        revealArtifactButton.target = self
        revealArtifactButton.action = #selector(revealSelectedArtifact)

        configureButton(deleteArtifactButton, title: "Delete", symbolName: "trash")
        deleteArtifactButton.target = self
        deleteArtifactButton.action = #selector(deleteSelectedArtifact)

        simulatorPopUpButton.target = self
        simulatorPopUpButton.action = #selector(simulatorSelectionChanged)

        configureButton(refreshSimulatorsButton, title: "Refresh", symbolName: "arrow.clockwise")
        refreshSimulatorsButton.target = self
        refreshSimulatorsButton.action = #selector(refreshSimulators)

        configureButton(installButton, title: "Install", symbolName: "iphone.and.arrow.forward")
        installButton.target = self
        installButton.action = #selector(installSelectedArtifact)
    }

    private func buildLayout() {
        view.addSubview(contentStack)
        contentStack.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(20)
        }

        let versionGrid = NSGridView(views: [
            [label("Current Version"), currentVersionLabel, NSView()],
            [label("Download Version"), versionTextField, resetVersionButton],
        ])
        configureGrid(versionGrid)
        versionGrid.column(at: 1).width = 260

        let downloadRow = NSStackView(views: [downloadButton, downloadProgressIndicator])
        downloadRow.orientation = .horizontal
        downloadRow.spacing = 12
        downloadRow.alignment = .centerY
        downloadProgressIndicator.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(360)
        }

        let downloadStack = NSStackView(views: [downloadRow, downloadStatusLabel])
        downloadStack.orientation = .vertical
        downloadStack.spacing = 8
        downloadStack.alignment = .leading

        let artifactControls = NSStackView(views: [artifactPopUpButton, revealArtifactButton, deleteArtifactButton])
        artifactControls.orientation = .horizontal
        artifactControls.spacing = 8
        artifactControls.alignment = .centerY
        artifactPopUpButton.snp.makeConstraints { make in
            make.width.greaterThanOrEqualTo(360)
        }

        let installGrid = NSGridView(views: [
            [label("RuntimeViewer.app"), artifactControls, NSView()],
            [label("Simulator"), simulatorPopUpButton, refreshSimulatorsButton],
            [NSView(), installButton, NSView()],
            [NSView(), installStatusLabel, NSView()],
        ])
        configureGrid(installGrid)
        installGrid.column(at: 1).width = 520

        contentStack.addArrangedSubview(section(title: "Version", content: versionGrid))
        contentStack.addArrangedSubview(section(title: "Download", content: downloadStack))
        contentStack.addArrangedSubview(section(title: "Install", content: installGrid))
    }

    private func render() {
        let isEditingVersion = view.window?.firstResponder === versionTextField.currentEditor()
        if !isEditingVersion {
            versionTextField.stringValue = viewModel.version
        }

        currentVersionLabel.stringValue = viewModel.currentVersion
        downloadButton.isEnabled = viewModel.canDownload
        resetVersionButton.isEnabled = !viewModel.isDownloading
        versionTextField.isEnabled = !viewModel.isDownloading

        downloadProgressIndicator.doubleValue = viewModel.downloadProgress ?? 0
        downloadStatusLabel.stringValue = viewModel.downloadStatus

        installButton.isEnabled = viewModel.canInstall
        revealArtifactButton.isEnabled = viewModel.selectedArtifact != nil
        deleteArtifactButton.isEnabled = viewModel.selectedArtifact != nil && !viewModel.isDownloading
        refreshSimulatorsButton.isEnabled = !viewModel.isInstalling
        installStatusLabel.stringValue = viewModel.installStatus

        renderArtifacts()
        renderSimulators()
    }

    private func renderArtifacts() {
        artifactPopUpButton.removeAllItems()

        guard !viewModel.artifacts.isEmpty else {
            artifactPopUpButton.addItem(withTitle: "No downloaded simulator apps")
            artifactPopUpButton.item(at: 0)?.isEnabled = false
            artifactPopUpButton.isEnabled = false
            return
        }

        artifactPopUpButton.isEnabled = !viewModel.isInstalling
        for artifact in viewModel.artifacts {
            artifactPopUpButton.addItem(withTitle: artifact.displayName)
            artifactPopUpButton.lastItem?.representedObject = artifact.id
        }

        if let selectedArtifactID = viewModel.selectedArtifactID,
           let index = viewModel.artifacts.firstIndex(where: { $0.id == selectedArtifactID }) {
            artifactPopUpButton.selectItem(at: index)
        } else {
            artifactPopUpButton.selectItem(at: 0)
        }
    }

    private func renderSimulators() {
        simulatorPopUpButton.removeAllItems()

        guard !viewModel.simulators.isEmpty else {
            simulatorPopUpButton.addItem(withTitle: "No available simulators")
            simulatorPopUpButton.item(at: 0)?.isEnabled = false
            simulatorPopUpButton.isEnabled = false
            return
        }

        simulatorPopUpButton.isEnabled = !viewModel.isInstalling
        for simulator in viewModel.simulators {
            simulatorPopUpButton.addItem(withTitle: simulator.displayName)
            simulatorPopUpButton.lastItem?.representedObject = simulator.id
        }

        if let selectedSimulatorID = viewModel.selectedSimulatorID,
           let index = viewModel.simulators.firstIndex(where: { $0.id == selectedSimulatorID }) {
            simulatorPopUpButton.selectItem(at: index)
        } else {
            simulatorPopUpButton.selectItem(at: 0)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        viewModel.version = versionTextField.stringValue
        downloadButton.isEnabled = viewModel.canDownload
    }

    @objc private func resetVersion() {
        viewModel.resetVersion()
    }

    @objc private func downloadSelectedVersion() {
        viewModel.version = versionTextField.stringValue
        viewModel.downloadSelectedVersion()
    }

    @objc private func artifactSelectionChanged() {
        viewModel.selectArtifact(id: artifactPopUpButton.selectedItem?.representedObject as? String)
    }

    @objc private func simulatorSelectionChanged() {
        viewModel.selectSimulator(id: simulatorPopUpButton.selectedItem?.representedObject as? String)
    }

    @objc private func refreshSimulators() {
        Task {
            await viewModel.refreshSimulators()
        }
    }

    @objc private func installSelectedArtifact() {
        viewModel.installSelectedArtifact()
    }

    @objc private func revealSelectedArtifact() {
        guard let artifact = viewModel.selectedArtifact else { return }
        NSWorkspace.shared.activateFileViewerSelecting([artifact.appURL])
    }

    @objc private func deleteSelectedArtifact() {
        viewModel.deleteSelectedArtifact()
    }

    private func section(title: String, content: NSView) -> NSView {
        let box = NSBox()
        box.title = title
        box.boxType = .primary
        box.contentViewMargins = NSSize(width: 14, height: 12)
        box.contentView?.addSubview(content)
        content.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        return box
    }

    private func configureGrid(_ grid: NSGridView) {
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).width = 130
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func configureStatusLabel(_ label: NSTextField) {
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func configureButton(_ button: NSButton, title: String, symbolName: String) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
    }
}

#endif
