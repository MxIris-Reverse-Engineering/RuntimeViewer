# Export Wizard Enhancement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Refactor the export UI into a multi-step wizard with NSTabViewController, supporting selective object export and separate ObjC/Swift format configuration.

**Architecture:** Replace the single `ExportingViewController` with an `ExportingTabViewController` (NSTabViewController) hosting 3 step VCs: Selection → Configuration → Progress/Completion. Each step has its own ViewController + ViewModel pair. A shared `ExportingState` object passes data between steps. The Tab VC creates all sub-VCs/VMs and manages tab transitions by observing navigation signals from each VM.

**Tech Stack:** AppKit, RxSwift, SnapKit, RuntimeViewerCore export APIs

---

## Context

**Key base classes:**
- `AppKitViewController<VM: ViewModelProtocol>` — provides `viewModel`, `setupBindings(for:)`, auto error handling
- `ViewModel<Route: Routable>` — provides `documentState`, `router`, `appDefaults`, `errorRelay`, `rx.disposeBag`
- `@Observed` property wrapper — backed by `BehaviorRelay`, use `$prop.asDriver()` for output

**Key APIs:**
- `RuntimeEngine.objects(in: imagePath) async throws -> [RuntimeObject]` — get all objects in an image
- `RuntimeEngine.exportInterface(for: object, options:) async throws -> RuntimeInterfaceExportItem` — export single object
- `RuntimeInterfaceExportWriter.writeSingleFile(items:to:imageName:reporter:)` — write combined .h/.swiftinterface
- `RuntimeInterfaceExportWriter.writeDirectory(items:to:reporter:)` — write individual files in subdirs
- `RuntimeObject.kind.isSwift` / `RuntimeObject.kind.isObjc` — kind checking via `@CaseCheckable`

**File locations (all under `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/`):**
- Old files to delete: `ExportingViewController.swift`, `ExportingViewModel.swift`
- New files: all 8 new files created in this directory

---

### Task 1: Create ExportingState

Shared state object that passes data between wizard steps.

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingState.swift`

**Step 1: Write the file**

```swift
import Foundation
import RuntimeViewerCore

enum ExportFormat: Int {
    case singleFile = 0
    case directory = 1
}

final class ExportingState {
    let imagePath: String
    let imageName: String

    var allObjects: [RuntimeObject] = []
    var selectedObjects: Set<RuntimeObject> = []

    var objcFormat: ExportFormat = .singleFile
    var swiftFormat: ExportFormat = .singleFile

    var destinationURL: URL?

    var objcObjects: [RuntimeObject] {
        allObjects.filter { !$0.kind.isSwift }
    }

    var swiftObjects: [RuntimeObject] {
        allObjects.filter { $0.kind.isSwift }
    }

    var selectedObjcObjects: [RuntimeObject] {
        objcObjects.filter { selectedObjects.contains($0) }
    }

    var selectedSwiftObjects: [RuntimeObject] {
        swiftObjects.filter { selectedObjects.contains($0) }
    }

    init(imagePath: String, imageName: String) {
        self.imagePath = imagePath
        self.imageName = imageName
    }
}
```

**Step 2: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingState.swift
git commit -m "feat(export): Add ExportingState shared state object"
```

---

### Task 2: Create ExportingSelectionViewModel

Step 1 ViewModel — loads objects, manages checkbox selection state.

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingSelectionViewModel.swift`

**Step 1: Write the file**

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingSelectionViewModel: ViewModel<MainRoute> {
    struct Input {
        let cancelClick: Signal<Void>
        let nextClick: Signal<Void>
        let toggleObject: Signal<RuntimeObject>
        let toggleAllObjC: Signal<Bool>
        let toggleAllSwift: Signal<Bool>
    }

    struct Output {
        let objcObjects: Driver<[RuntimeObject]>
        let swiftObjects: Driver<[RuntimeObject]>
        let selectedObjects: Driver<Set<RuntimeObject>>
        let summaryText: Driver<String>
        let isNextEnabled: Driver<Bool>
        let isLoading: Driver<Bool>
    }

    @Observed private(set) var objcObjects: [RuntimeObject] = []
    @Observed private(set) var swiftObjects: [RuntimeObject] = []
    @Observed private(set) var selectedObjects: Set<RuntimeObject> = []
    @Observed private(set) var isLoading: Bool = true

    let nextRelay = PublishRelay<Void>()

    private let exportingState: ExportingState

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
        loadObjects()
    }

    private func loadObjects() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let objects = try await documentState.runtimeEngine.objects(in: exportingState.imagePath)
                let objc = objects.filter { !$0.kind.isSwift }
                let swift = objects.filter { $0.kind.isSwift }
                self.objcObjects = objc
                self.swiftObjects = swift
                self.selectedObjects = Set(objects)
                self.exportingState.allObjects = objects
                self.isLoading = false
            } catch {
                errorRelay.accept(error)
            }
        }
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.nextClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportingState.selectedObjects = selectedObjects
            nextRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.toggleObject.emitOnNext { [weak self] object in
            guard let self else { return }
            if selectedObjects.contains(object) {
                selectedObjects.remove(object)
            } else {
                selectedObjects.insert(object)
            }
        }
        .disposed(by: rx.disposeBag)

        input.toggleAllObjC.emitOnNext { [weak self] selected in
            guard let self else { return }
            if selected {
                selectedObjects.formUnion(objcObjects)
            } else {
                selectedObjects.subtract(objcObjects)
            }
        }
        .disposed(by: rx.disposeBag)

        input.toggleAllSwift.emitOnNext { [weak self] selected in
            guard let self else { return }
            if selected {
                selectedObjects.formUnion(swiftObjects)
            } else {
                selectedObjects.subtract(swiftObjects)
            }
        }
        .disposed(by: rx.disposeBag)

        let summaryText = $selectedObjects.asDriver().map { [weak self] selected -> String in
            guard let self else { return "" }
            let objcCount = objcObjects.filter { selected.contains($0) }.count
            let swiftCount = swiftObjects.filter { selected.contains($0) }.count
            return "\(objcCount + swiftCount) items selected (\(objcCount) ObjC, \(swiftCount) Swift)"
        }

        let isNextEnabled = $selectedObjects.asDriver().map { !$0.isEmpty }

        return Output(
            objcObjects: $objcObjects.asDriver(),
            swiftObjects: $swiftObjects.asDriver(),
            selectedObjects: $selectedObjects.asDriver(),
            summaryText: summaryText,
            isNextEnabled: isNextEnabled,
            isLoading: $isLoading.asDriver()
        )
    }
}
```

**Step 2: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingSelectionViewModel.swift
git commit -m "feat(export): Add ExportingSelectionViewModel for Step 1"
```

---

### Task 3: Create ExportingSelectionViewController

Step 1 VC — NSTableView with checkbox groups for ObjC/Swift, select all toggles, summary label.

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingSelectionViewController.swift`

**Step 1: Write the file**

The table view uses a flat list with two kinds of rows: group headers (bold, with select-all checkbox) and object rows (indented, with individual checkbox). Checkbox clicks route through relays to the ViewModel.

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingSelectionViewController: AppKitViewController<ExportingSelectionViewModel> {
    // MARK: - Types

    private enum SelectionGroup: Int, CaseIterable {
        case objc = 0
        case swift = 1

        var title: String {
            switch self {
            case .objc: return "Objective-C"
            case .swift: return "Swift"
            }
        }
    }

    private enum SelectionItem {
        case group(SelectionGroup)
        case object(RuntimeObject)
    }

    // MARK: - Relays

    private let cancelRelay = PublishRelay<Void>()
    private let nextRelay = PublishRelay<Void>()
    private let toggleObjectRelay = PublishRelay<RuntimeObject>()
    private let toggleAllObjCRelay = PublishRelay<Bool>()
    private let toggleAllSwiftRelay = PublishRelay<Bool>()

    // MARK: - State

    private var items: [SelectionItem] = []
    private var objcObjects: [RuntimeObject] = []
    private var swiftObjects: [RuntimeObject] = []
    private var selectedObjects: Set<RuntimeObject> = []

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = ScrollView()
    private let summaryLabel = Label()
    private let nextButton = PushButton()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()

        let iconImageView = ImageView().then {
            $0.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
            $0.symbolConfiguration = .init(pointSize: 32, weight: .light)
            $0.contentTintColor = .controlAccentColor
        }

        let titleLabel = Label("Export Interfaces").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
        }

        let headerStack = HStackView(spacing: 10) {
            iconImageView
            titleLabel
        }.then {
            $0.alignment = .centerY
        }

        let column = NSTableColumn(identifier: .init("main"))
        column.title = ""
        tableView.do {
            $0.addTableColumn(column)
            $0.headerView = nil
            $0.dataSource = self
            $0.delegate = self
            $0.selectionHighlightStyle = .none
            $0.rowHeight = 24
            $0.intercellSpacing = NSSize(width: 0, height: 2)
        }

        scrollView.do {
            $0.documentView = tableView
            $0.hasVerticalScroller = true
        }

        summaryLabel.do {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        nextButton.do {
            $0.title = "Next"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(nextClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            cancelButton
            nextButton
        }

        view.hierarchy {
            headerStack
            scrollView
            summaryLabel
            buttonStack
        }

        headerStack.snp.makeConstraints { make in
            make.top.leading.equalToSuperview().inset(20)
        }

        scrollView.snp.makeConstraints { make in
            make.top.equalTo(headerStack.snp.bottom).offset(16)
            make.leading.trailing.equalToSuperview().inset(20)
            make.bottom.equalTo(summaryLabel.snp.top).offset(-8)
        }

        summaryLabel.snp.makeConstraints { make in
            make.leading.equalToSuperview().inset(20)
            make.bottom.equalTo(buttonStack.snp.top).offset(-12)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelRelay.accept(())
    }

    @objc private func nextClicked() {
        nextRelay.accept(())
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0, row < items.count else { return }
        let item = items[row]
        switch item {
        case .group(let group):
            let nextState: Bool = sender.state != .off
            switch group {
            case .objc: toggleAllObjCRelay.accept(nextState)
            case .swift: toggleAllSwiftRelay.accept(nextState)
            }
        case .object(let object):
            toggleObjectRelay.accept(object)
        }
    }

    // MARK: - Data

    private func rebuildItems() {
        items = []
        if !objcObjects.isEmpty {
            items.append(.group(.objc))
            items += objcObjects.map { .object($0) }
        }
        if !swiftObjects.isEmpty {
            items.append(.group(.swift))
            items += swiftObjects.map { .object($0) }
        }
        tableView.reloadData()
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ExportingSelectionViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingSelectionViewModel.Input(
            cancelClick: cancelRelay.asSignal(),
            nextClick: nextRelay.asSignal(),
            toggleObject: toggleObjectRelay.asSignal(),
            toggleAllObjC: toggleAllObjCRelay.asSignal(),
            toggleAllSwift: toggleAllSwiftRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.objcObjects.driveOnNext { [weak self] objects in
            guard let self else { return }
            self.objcObjects = objects
            rebuildItems()
        }
        .disposed(by: rx.disposeBag)

        output.swiftObjects.driveOnNext { [weak self] objects in
            guard let self else { return }
            self.swiftObjects = objects
            rebuildItems()
        }
        .disposed(by: rx.disposeBag)

        output.selectedObjects.driveOnNext { [weak self] selected in
            guard let self else { return }
            self.selectedObjects = selected
            tableView.reloadData()
        }
        .disposed(by: rx.disposeBag)

        output.summaryText.drive(summaryLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.isNextEnabled.driveOnNext { [weak self] enabled in
            guard let self else { return }
            nextButton.isEnabled = enabled
        }
        .disposed(by: rx.disposeBag)
    }
}

// MARK: - NSTableViewDataSource

extension ExportingSelectionViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }
}

// MARK: - NSTableViewDelegate

extension ExportingSelectionViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        switch item {
        case .group(let group):
            let objects = group == .objc ? objcObjects : swiftObjects
            let selectedCount = objects.filter { selectedObjects.contains($0) }.count

            let checkbox = NSButton(checkboxWithTitle: "\(group.title) (\(objects.count))", target: self, action: #selector(checkboxClicked(_:)))
            checkbox.font = .systemFont(ofSize: 13, weight: .semibold)
            checkbox.tag = row
            checkbox.allowsMixedState = true
            checkbox.state = selectedCount == 0 ? .off : (selectedCount == objects.count ? .on : .mixed)

            let container = NSView()
            container.addSubview(checkbox)
            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(4)
                make.centerY.equalToSuperview()
            }
            return container

        case .object(let object):
            let checkbox = NSButton(checkboxWithTitle: object.displayName, target: self, action: #selector(checkboxClicked(_:)))
            checkbox.font = .systemFont(ofSize: 13)
            checkbox.tag = row
            checkbox.state = selectedObjects.contains(object) ? .on : .off

            let container = NSView()
            container.addSubview(checkbox)
            checkbox.snp.makeConstraints { make in
                make.leading.equalToSuperview().offset(24)
                make.centerY.equalToSuperview()
            }
            return container
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        switch items[row] {
        case .group: return 28
        case .object: return 22
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        false
    }
}
```

**Step 2: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingSelectionViewController.swift
git commit -m "feat(export): Add ExportingSelectionViewController for Step 1"
```

---

### Task 4: Create ExportingConfigurationViewModel + ViewController

Step 2 — separate ObjC/Swift format selection (single file or directory).

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewModel.swift`
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewController.swift`

**Step 1: Write ExportingConfigurationViewModel**

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingConfigurationViewModel: ViewModel<MainRoute> {
    struct Input {
        let cancelClick: Signal<Void>
        let backClick: Signal<Void>
        let exportClick: Signal<Void>
        let objcFormatSelected: Signal<Int>
        let swiftFormatSelected: Signal<Int>
    }

    struct Output {
        let objcCount: Driver<Int>
        let swiftCount: Driver<Int>
        let hasObjC: Driver<Bool>
        let hasSwift: Driver<Bool>
        let imageName: Driver<String>
    }

    @Observed private(set) var objcCount: Int = 0
    @Observed private(set) var swiftCount: Int = 0
    @Observed private(set) var hasObjC: Bool = false
    @Observed private(set) var hasSwift: Bool = false

    let backRelay = PublishRelay<Void>()
    let exportClickedRelay = PublishRelay<Void>()

    private let exportingState: ExportingState

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func refreshFromState() {
        let objc = exportingState.selectedObjcObjects
        let swift = exportingState.selectedSwiftObjects
        objcCount = objc.count
        swiftCount = swift.count
        hasObjC = !objc.isEmpty
        hasSwift = !swift.isEmpty
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.backClick.emitOnNext { [weak self] in
            guard let self else { return }
            backRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.exportClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportClickedRelay.accept(())
        }
        .disposed(by: rx.disposeBag)

        input.objcFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.objcFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        input.swiftFormatSelected.emitOnNext { [weak self] index in
            guard let self else { return }
            exportingState.swiftFormat = ExportFormat(rawValue: index) ?? .singleFile
        }
        .disposed(by: rx.disposeBag)

        return Output(
            objcCount: $objcCount.asDriver(),
            swiftCount: $swiftCount.asDriver(),
            hasObjC: $hasObjC.asDriver(),
            hasSwift: $hasSwift.asDriver(),
            imageName: .just(exportingState.imageName)
        )
    }
}
```

**Step 2: Write ExportingConfigurationViewController**

```swift
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
```

**Step 3: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewModel.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewController.swift
git commit -m "feat(export): Add ExportingConfigurationViewController/ViewModel for Step 2"
```

---

### Task 5: Create ExportingProgressViewModel + ViewController

Step 3 — performs export, shows progress, displays completion summary.

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewModel.swift`
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewController.swift`

**Step 1: Write ExportingProgressViewModel**

This VM uses `RuntimeEngine.exportInterface(for:options:)` per selected object and tracks progress manually. It then calls `RuntimeInterfaceExportWriter` with separate formats for ObjC and Swift items.

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingProgressViewModel: ViewModel<MainRoute> {
    enum Page {
        case progress
        case completion
    }

    struct ExportResult {
        let succeeded: Int
        let failed: Int
        let totalDuration: TimeInterval
        let objcCount: Int
        let swiftCount: Int
    }

    struct Input {
        let cancelClick: Signal<Void>
        let doneClick: Signal<Void>
        let showInFinderClick: Signal<Void>
    }

    struct Output {
        let currentPage: Driver<Page>
        let phaseText: Driver<String>
        let progressValue: Driver<Double>
        let currentObjectText: Driver<String>
        let result: Driver<ExportResult?>
    }

    @Observed private(set) var currentPage: Page = .progress
    @Observed private(set) var phaseText: String = "Preparing..."
    @Observed private(set) var progressValue: Double = 0
    @Observed private(set) var currentObjectText: String = ""
    @Observed private(set) var exportResult: ExportResult?

    private let exportingState: ExportingState
    private var exportTask: Task<Void, Never>?

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        super.init(documentState: documentState, router: router)
    }

    func transform(_ input: Input) -> Output {
        input.cancelClick.emitOnNext { [weak self] in
            guard let self else { return }
            exportTask?.cancel()
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.doneClick.emitOnNext { [weak self] in
            guard let self else { return }
            router.trigger(.dismiss)
        }
        .disposed(by: rx.disposeBag)

        input.showInFinderClick.emitOnNext { [weak self] in
            guard let self else { return }
            guard let url = exportingState.destinationURL else { return }
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        .disposed(by: rx.disposeBag)

        return Output(
            currentPage: $currentPage.asDriver(),
            phaseText: $phaseText.asDriver(),
            progressValue: $progressValue.asDriver(),
            currentObjectText: $currentObjectText.asDriver(),
            result: $exportResult.asDriver()
        )
    }

    func startExport() {
        guard let directory = exportingState.destinationURL else { return }

        currentPage = .progress
        phaseText = "Exporting interfaces..."
        progressValue = 0
        currentObjectText = ""
        exportResult = nil

        let selectedObjcObjects = exportingState.selectedObjcObjects
        let selectedSwiftObjects = exportingState.selectedSwiftObjects
        let allSelected = selectedObjcObjects + selectedSwiftObjects

        exportTask = Task { [weak self] in
            guard let self else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            var items: [RuntimeInterfaceExportItem] = []
            var succeeded = 0
            var failed = 0

            do {
                for (index, object) in allSelected.enumerated() {
                    if Task.isCancelled { break }

                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        progressValue = Double(index) / Double(allSelected.count)
                        currentObjectText = "\(object.displayName) (\(index + 1)/\(allSelected.count))"
                    }

                    do {
                        let item = try await documentState.runtimeEngine.exportInterface(
                            for: object,
                            options: appDefaults.options
                        )
                        items.append(item)
                        succeeded += 1
                    } catch {
                        failed += 1
                    }
                }

                guard !Task.isCancelled else { return }

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    phaseText = "Writing files..."
                    progressValue = 1.0
                }

                try writeItems(items, to: directory)

                let duration = CFAbsoluteTimeGetCurrent() - startTime
                let objcCount = items.filter { !$0.isSwift }.count
                let swiftCount = items.filter { $0.isSwift }.count

                let result = ExportResult(
                    succeeded: succeeded,
                    failed: failed,
                    totalDuration: duration,
                    objcCount: objcCount,
                    swiftCount: swiftCount
                )

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    exportResult = result
                    currentPage = .completion
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    errorRelay.accept(error)
                }
            }
        }
    }

    private func writeItems(_ items: [RuntimeInterfaceExportItem], to directory: URL) throws {
        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let reporter = RuntimeInterfaceExportReporter()
            switch exportingState.objcFormat {
            case .singleFile:
                try RuntimeInterfaceExportWriter.writeSingleFile(
                    items: objcItems,
                    to: directory,
                    imageName: exportingState.imageName,
                    reporter: reporter
                )
            case .directory:
                try RuntimeInterfaceExportWriter.writeDirectory(
                    items: objcItems,
                    to: directory,
                    reporter: reporter
                )
            }
        }

        if !swiftItems.isEmpty {
            let reporter = RuntimeInterfaceExportReporter()
            switch exportingState.swiftFormat {
            case .singleFile:
                try RuntimeInterfaceExportWriter.writeSingleFile(
                    items: swiftItems,
                    to: directory,
                    imageName: exportingState.imageName,
                    reporter: reporter
                )
            case .directory:
                try RuntimeInterfaceExportWriter.writeDirectory(
                    items: swiftItems,
                    to: directory,
                    reporter: reporter
                )
            }
        }
    }
}
```

**Step 2: Write ExportingProgressViewController**

Two internal pages (progress view and completion view) managed by the same showPage pattern.

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingProgressViewController: AppKitViewController<ExportingProgressViewModel> {
    // MARK: - Relays

    private let cancelRelay = PublishRelay<Void>()
    private let doneRelay = PublishRelay<Void>()
    private let showInFinderRelay = PublishRelay<Void>()

    // MARK: - Progress Page

    private let progressPhaseLabel = Label("Preparing...").then {
        $0.font = .systemFont(ofSize: 15, weight: .medium)
        $0.alignment = .center
    }

    private let progressIndicator = NSProgressIndicator().then {
        $0.style = .bar
        $0.isIndeterminate = false
        $0.minValue = 0
        $0.maxValue = 1
    }

    private let progressObjectLabel = Label().then {
        $0.font = .systemFont(ofSize: 12)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
    }

    private lazy var progressPageView: NSView = {
        let container = NSView()

        let contentStack = VStackView(alignment: .centerX, spacing: 12) {
            progressPhaseLabel
            progressIndicator
            progressObjectLabel
        }

        let cancelButton = PushButton().then {
            $0.title = "Cancel"
            $0.keyEquivalent = "\u{1b}"
            $0.target = self
            $0.action = #selector(cancelClicked)
        }

        container.hierarchy {
            contentStack
            cancelButton
        }

        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(350)
        }

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
            make.leading.greaterThanOrEqualToSuperview().offset(20)
            make.trailing.lessThanOrEqualToSuperview().offset(-20)
        }

        cancelButton.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    // MARK: - Completion Page

    private let completionSummaryLabel = Label().then {
        $0.font = .systemFont(ofSize: 13)
        $0.textColor = .secondaryLabelColor
        $0.alignment = .center
        $0.maximumNumberOfLines = 0
        $0.preferredMaxLayoutWidth = 350
    }

    private lazy var completionPageView: NSView = {
        let container = NSView()

        let checkmarkImageView = ImageView().then {
            $0.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            $0.symbolConfiguration = .init(pointSize: 48, weight: .light)
            $0.contentTintColor = .systemGreen
        }

        let titleLabel = Label("Export Complete").then {
            $0.font = .systemFont(ofSize: 18, weight: .semibold)
            $0.alignment = .center
        }

        let contentStack = VStackView(alignment: .centerX, spacing: 8) {
            checkmarkImageView
            titleLabel
            completionSummaryLabel
        }

        let showInFinderButton = PushButton().then {
            $0.title = "Show in Finder"
            $0.target = self
            $0.action = #selector(showInFinderClicked)
        }

        let doneButton = PushButton().then {
            $0.title = "Done"
            $0.keyEquivalent = "\r"
            $0.target = self
            $0.action = #selector(doneClicked)
        }

        let buttonStack = HStackView(spacing: 8) {
            showInFinderButton
            doneButton
        }

        container.hierarchy {
            contentStack
            buttonStack
        }

        contentStack.snp.makeConstraints { make in
            make.centerX.equalToSuperview()
            make.centerY.equalToSuperview().offset(-20)
        }

        buttonStack.snp.makeConstraints { make in
            make.trailing.bottom.equalToSuperview().inset(20)
        }

        return container
    }()

    // MARK: - Container

    private let containerView = NSView()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView()
        view.addSubview(containerView)

        containerView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        showPage(progressPageView)
    }

    // MARK: - Actions

    @objc private func cancelClicked() {
        cancelRelay.accept(())
    }

    @objc private func doneClicked() {
        doneRelay.accept(())
    }

    @objc private func showInFinderClicked() {
        showInFinderRelay.accept(())
    }

    // MARK: - Page Management

    private func showPage(_ page: NSView) {
        containerView.subviews.forEach { $0.removeFromSuperview() }
        containerView.addSubview(page)
        page.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    // MARK: - Bindings

    override func setupBindings(for viewModel: ExportingProgressViewModel) {
        super.setupBindings(for: viewModel)

        let input = ExportingProgressViewModel.Input(
            cancelClick: cancelRelay.asSignal(),
            doneClick: doneRelay.asSignal(),
            showInFinderClick: showInFinderRelay.asSignal()
        )

        let output = viewModel.transform(input)

        output.currentPage.driveOnNext { [weak self] page in
            guard let self else { return }
            switch page {
            case .progress:
                showPage(progressPageView)
            case .completion:
                showPage(completionPageView)
            }
        }
        .disposed(by: rx.disposeBag)

        output.phaseText.drive(progressPhaseLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.progressValue.driveOnNext { [weak self] value in
            guard let self else { return }
            progressIndicator.doubleValue = value
        }
        .disposed(by: rx.disposeBag)

        output.currentObjectText.drive(progressObjectLabel.rx.stringValue).disposed(by: rx.disposeBag)

        output.result.compactMap { $0 }.driveOnNext { [weak self] result in
            guard let self else { return }
            var lines: [String] = []
            lines.append("\(result.succeeded) interfaces exported successfully")
            if result.failed > 0 {
                lines.append("\(result.failed) failed")
            }
            lines.append(String(format: "Duration: %.1fs", result.totalDuration))
            lines.append("ObjC: \(result.objcCount) | Swift: \(result.swiftCount)")
            completionSummaryLabel.stringValue = lines.joined(separator: "\n")
        }
        .disposed(by: rx.disposeBag)
    }
}
```

**Step 3: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewModel.swift \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewController.swift
git commit -m "feat(export): Add ExportingProgressViewController/ViewModel for Step 3"
```

---

### Task 6: Create ExportingTabViewController

NSTabViewController container that hosts all 3 step VCs and manages tab transitions.

**Files:**
- Create: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingTabViewController.swift`

**Step 1: Write the file**

```swift
import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

final class ExportingTabViewController: NSTabViewController {
    private let exportingState: ExportingState
    private let documentState: DocumentState
    private let router: any Router<MainRoute>

    private var selectionVM: ExportingSelectionViewModel!
    private var configurationVM: ExportingConfigurationViewModel!
    private var progressVM: ExportingProgressViewModel!

    private var disposeBag = DisposeBag()

    init(exportingState: ExportingState, documentState: DocumentState, router: any Router<MainRoute>) {
        self.exportingState = exportingState
        self.documentState = documentState
        self.router = router
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        tabStyle = .unspecified
        preferredContentSize = NSSize(width: 550, height: 450)

        // Step 1: Selection
        let selectionVC = ExportingSelectionViewController()
        selectionVM = ExportingSelectionViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        selectionVC.setupBindings(for: selectionVM)

        // Step 2: Configuration
        let configurationVC = ExportingConfigurationViewController()
        configurationVM = ExportingConfigurationViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        configurationVC.setupBindings(for: configurationVM)

        // Step 3: Progress
        let progressVC = ExportingProgressViewController()
        progressVM = ExportingProgressViewModel(
            exportingState: exportingState,
            documentState: documentState,
            router: router
        )
        progressVC.setupBindings(for: progressVM)

        // Add tab items
        addTabViewItem(NSTabViewItem(viewController: selectionVC))
        addTabViewItem(NSTabViewItem(viewController: configurationVC))
        addTabViewItem(NSTabViewItem(viewController: progressVC))

        selectedTabViewItemIndex = 0

        setupNavigationBindings()
    }

    private func setupNavigationBindings() {
        // Selection → Configuration
        selectionVM.nextRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            configurationVM.refreshFromState()
            selectedTabViewItemIndex = 1
        }
        .disposed(by: disposeBag)

        // Configuration → Selection (back)
        configurationVM.backRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            selectedTabViewItemIndex = 0
        }
        .disposed(by: disposeBag)

        // Configuration → Export (directory picker → Progress)
        configurationVM.exportClickedRelay.asSignal().emitOnNext { [weak self] in
            guard let self else { return }
            presentDirectoryPicker()
        }
        .disposed(by: disposeBag)
    }

    private func presentDirectoryPicker() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = "Choose a destination folder for exported interfaces"

        guard let window = view.window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return }
            exportingState.destinationURL = url
            selectedTabViewItemIndex = 2
            progressVM.startExport()
        }
    }
}
```

**Step 2: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 3: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingTabViewController.swift
git commit -m "feat(export): Add ExportingTabViewController container"
```

---

### Task 7: Update MainCoordinator and delete old files

Wire the new ExportingTabViewController into the existing routing. Delete old single-VC export files.

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift`
- Delete: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingViewController.swift`
- Delete: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingViewModel.swift`

**Step 1: Update MainCoordinator**

Replace the `.exportInterfaces` case in `prepareTransition(for:)`.

Find this block (around line 70-78):

```swift
case .exportInterfaces:
    guard let imagePath = documentState.currentImagePath,
          let imageName = documentState.currentImageName else {
        return .none()
    }
    let viewController = ExportingViewController()
    let viewModel = ExportingViewModel(imagePath: imagePath, imageName: imageName, documentState: documentState, router: self)
    viewController.setupBindings(for: viewModel)
    return .presentOnRoot(viewController, mode: .asSheet)
```

Replace with:

```swift
case .exportInterfaces:
    guard let imagePath = documentState.currentImagePath,
          let imageName = documentState.currentImageName else {
        return .none()
    }
    let state = ExportingState(imagePath: imagePath, imageName: imageName)
    let tabViewController = ExportingTabViewController(
        exportingState: state,
        documentState: documentState,
        router: self
    )
    return .presentOnRoot(tabViewController, mode: .asSheet)
```

**Step 2: Delete old files**

```bash
git rm RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingViewController.swift
git rm RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingViewModel.swift
```

**NOTE:** Also remove these files from the Xcode project if they are referenced in the `.pbxproj`. Use Xcode MCP tools or manual editing.

**Step 3: Build**

```bash
xcodebuild build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

**Step 4: Commit**

```bash
git add -A RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ \
        RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Main/MainCoordinator.swift
git commit -m "feat(export): Wire ExportingTabViewController and remove old export files"
```

---

### Task 8: Final build verification

**Step 1: Clean build**

```bash
xcodebuild clean build -workspace RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: 0 errors

**Step 2: Verify all new files are tracked**

```bash
git status
```

All files should be committed with no untracked export files.
