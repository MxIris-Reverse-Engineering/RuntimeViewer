# IDA Compatible ObjC Export Mode - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add an "IDA Compatible" export mode that generates ivar layout structs with `__fixed`/`__at` annotations, clean ObjC headers, and `.ida_map` IMP mapping files for IDA Pro 9.3+.

**Architecture:** The feature adds a single `idaCompatible` boolean that flows through the existing export pipeline: `ExportingState` → `ExportingConfigurationViewModel` → `ExportingProgressViewModel` → `RuntimeInterfaceExportConfiguration` → `RuntimeEngine.exportInterfaces()`. When enabled, it force-overrides comment options to produce clean headers, prepends ivar layout structs in `ObjCClassInfo.semanticString()`, collects IMP mappings during interface generation, and writes an `.ida_map` file alongside the exported headers.

**Tech Stack:** Swift, AppKit, RxSwift, SemanticString/SemanticStringBuilder, MetaCodable (@Codable/@MemberInit/@Default)

---

### Task 1: Add `idaCompatible` to `ObjCGenerationOptions`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift:14-37`

**Step 1: Add the new option field**

In `ObjCGenerationOptions`, add `idaCompatible` after line 25 (`addPropertyAccessorAddressComments`):

```swift
@Codable
@MemberInit
public struct ObjCGenerationOptions: Sendable, Equatable {
    @Default(false) public var stripProtocolConformance: Bool
    @Default(false) public var stripOverrides: Bool
    @Default(false) public var stripSynthesizedIvars: Bool
    @Default(false) public var stripSynthesizedMethods: Bool
    @Default(false) public var stripCtorMethod: Bool
    @Default(false) public var stripDtorMethod: Bool
    @Default(false) public var addIvarOffsetComments: Bool
    @Default(false) public var addPropertyAttributesComments: Bool
    @Default(false) public var addMethodIMPAddressComments: Bool
    @Default(false) public var addPropertyAccessorAddressComments: Bool
    @Default(false) public var idaCompatible: Bool
    public static let `default` = Self()
}
```

**Step 2: Add force-override in `interface(for:using:transformer:)`**

In `RuntimeObjCSection.interface(for:using:transformer:)` (line 318), after `let objcDumpContext = ...` (line 322-329), add option override logic:

```swift
func interface(for object: RuntimeObject, using options: ObjCGenerationOptions, transformer: Transformer.ObjCConfiguration) async throws -> RuntimeObjectInterface {
    #log(.debug, "Generating interface for: \(object.name, privacy: .public)")
    let name = object.withImagePath(imagePath)

    var effectiveOptions = options
    if effectiveOptions.idaCompatible {
        effectiveOptions.addIvarOffsetComments = false
        effectiveOptions.addMethodIMPAddressComments = false
        effectiveOptions.addPropertyAccessorAddressComments = false
        effectiveOptions.addPropertyAttributesComments = false
    }

    let cTypeReplacements = transformer.cType.isEnabled ? transformer.cType.replacements : [:]
    let objcDumpContext = ObjCDumpContext(machO: machO, options: effectiveOptions, cTypeReplacements: cTypeReplacements) { name, isStruct in
        // ... existing closure ...
    }
    // ... rest unchanged ...
```

**Step 3: Collect IMP mappings for all methods when `idaCompatible`**

Currently, `methodIMPs`/`classMethodIMPs` are only populated when `addPropertyAccessorAddressComments` is true (lines 433-440). When `idaCompatible` is true, we also need all method IMPs for the `.ida_map` file. Modify the class case (around line 432):

```swift
if let finalClassInfo {
    if effectiveOptions.addPropertyAccessorAddressComments || effectiveOptions.idaCompatible {
        for method in currentClassInfo.methods where method.imp != 0 {
            objcDumpContext.methodIMPs[method.name] = method.imp
        }
        for method in currentClassInfo.classMethods where method.imp != 0 {
            objcDumpContext.classMethodIMPs[method.name] = method.imp
        }
    }
    // ... return ...
}
```

Do the same for category case (around line 526).

**Step 4: Build IMP mappings from context and return them**

After generating the semantic string, collect IMP mappings from `objcDumpContext` and attach to the returned `RuntimeObjectInterface`. This requires Task 2 (adding `impMappings` to `RuntimeObjectInterface`) to be done first, so we'll come back to wire this up.

**Step 5: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
git commit -m "feat(ida): add idaCompatible option to ObjCGenerationOptions with force-override"
```

---

### Task 2: Add `RuntimeIMPMapping` and extend `RuntimeObjectInterface`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportEvent.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface.swift`

**Step 1: Add `RuntimeIMPMapping` struct**

In `RuntimeInterfaceExportEvent.swift`, add after the `RuntimeInterfaceExportResult` struct:

```swift
public struct RuntimeIMPMapping: Sendable, Codable {
    public let address: String
    public let selector: String

    public init(address: String, selector: String) {
        self.address = address
        self.selector = selector
    }
}
```

**Step 2: Add `impMappings` to `RuntimeObjectInterface`**

In `RuntimeObjectInterface.swift`:

```swift
public struct RuntimeObjectInterface: Codable, Sendable {
    public let object: RuntimeObject
    public let interfaceString: SemanticString
    public let impMappings: [RuntimeIMPMapping]

    public init(object: RuntimeObject, interfaceString: SemanticString, impMappings: [RuntimeIMPMapping] = []) {
        self.object = object
        self.interfaceString = interfaceString
        self.impMappings = impMappings
    }
}
```

**Step 3: Update all existing `.init(object:, interfaceString:)` call sites**

Since the new parameter has a default value `= []`, existing call sites like `.init(object: name, interfaceString: ...)` will continue to compile. However, we need to update the class/category cases in `RuntimeObjCSection.interface(for:using:transformer:)` to pass IMP mappings when `idaCompatible`.

In the class case (around line 441), change:

```swift
if let finalClassInfo {
    if effectiveOptions.addPropertyAccessorAddressComments || effectiveOptions.idaCompatible {
        for method in currentClassInfo.methods where method.imp != 0 {
            objcDumpContext.methodIMPs[method.name] = method.imp
        }
        for method in currentClassInfo.classMethods where method.imp != 0 {
            objcDumpContext.classMethodIMPs[method.name] = method.imp
        }
    }

    let impMappings: [RuntimeIMPMapping]
    if effectiveOptions.idaCompatible {
        impMappings = buildIMPMappings(
            className: currentClassInfo.name,
            methods: currentClassInfo.methods,
            classMethods: currentClassInfo.classMethods,
            machO: machO
        )
    } else {
        impMappings = []
    }

    return .init(
        object: name,
        interfaceString: finalClassInfo.semanticString(using: objcDumpContext),
        impMappings: impMappings
    )
}
```

For the category case (around line 534), similarly:

```swift
let impMappings: [RuntimeIMPMapping]
if effectiveOptions.idaCompatible {
    impMappings = buildIMPMappings(
        className: categoryInfo.className + "(" + categoryInfo.categoryName + ")",
        methods: categoryInfo.methods,
        classMethods: categoryInfo.classMethods,
        machO: machO
    )
} else {
    impMappings = []
}
return .init(
    object: name,
    interfaceString: categoryInfo.semanticString(using: objcDumpContext),
    impMappings: impMappings
)
```

**Step 4: Add `buildIMPMappings` helper to `RuntimeObjCSection`**

Add a private helper method in the `RuntimeObjCSection` actor:

```swift
private func buildIMPMappings(
    className: String,
    methods: [ObjCMethodInfo],
    classMethods: [ObjCMethodInfo],
    machO: MachOImage
) -> [RuntimeIMPMapping] {
    var mappings: [RuntimeIMPMapping] = []
    for method in methods where method.imp != 0 {
        let address = "0x" + machO.addressString(forOffset: .init(method.imp.uint - machO.ptr.bitPattern.uint))
        mappings.append(.init(address: address, selector: "-[\(className) \(method.name)]"))
    }
    for method in classMethods where method.imp != 0 {
        let address = "0x" + machO.addressString(forOffset: .init(method.imp.uint - machO.ptr.bitPattern.uint))
        mappings.append(.init(address: address, selector: "+[\(className) \(method.name)]"))
    }
    return mappings
}
```

Note: Check how `addressString(forOffset:)` is called in the existing code (line 386: `context.machO.addressString(forOffset: .init(imp.uint - context.machO.ptr.bitPattern.uint))`). Use the same pattern.

**Step 5: Check `ObjCCategoryInfo` fields**

Before writing category IMP mapping code, verify `ObjCCategoryInfo` has `className` and `categoryName` fields. Search for the struct definition.

**Step 6: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportEvent.swift \
      RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface.swift \
      RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
git commit -m "feat(ida): add RuntimeIMPMapping and collect IMP addresses during export"
```

---

### Task 3: Add ivar layout struct generation

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/ObjCDump+SemanticString.swift:20-78`

**Step 1: Add `idaIvarLayoutStruct` method**

After the existing `ObjCClassInfo.semanticString(using:)` method (after line 78), add:

```swift
extension ObjCClassInfo {
    @SemanticStringBuilder
    func idaIvarLayoutStruct(using context: ObjCDumpContext) -> SemanticString {
        Keyword("struct")
        Space()
        "__fixed(0x\(String(instanceSize, radix: 16, uppercase: true)))"
        Space()
        TypeDeclaration(kind: .struct, "\(name)_IVARS")
        Space()
        "{"

        MemberList(level: 1) {
            for ivar in ivars {
                ivar.idaLayoutEntry(using: context)
            }
        }

        "};"
        BreakLine()
        BreakLine()
    }
}
```

**Step 2: Add `idaLayoutEntry` method on `ObjCIvarInfo`**

After the `idaIvarLayoutStruct` method, add:

```swift
extension ObjCIvarInfo {
    @SemanticStringBuilder
    func idaLayoutEntry(using context: ObjCDumpContext) -> SemanticString {
        "__at(0x\(String(offset, radix: 16, uppercase: true).leftPadding(toLength: 4, withPad: "0")))"
        Space()

        if let type, case .bitField(let width) = type {
            ObjCField(type: .int, name: name, bitWidth: width)
                .semanticString(fallbackName: name, context: context)
        } else {
            if [.char, .uchar].contains(type) {
                Keyword("BOOL")
                Space()
                Variable(name)
                ";"
            } else {
                if let type = type?.semanticDecoded(context: context) {
                    type
                    if type.string.last != "*" {
                        Space()
                    }
                    Variable(name)
                    if let currentArray = context.currentArray {
                        currentArray
                        context.currentArray = nil
                    }
                    ";"
                } else {
                    UnknownError()
                    Space()
                    Variable(name)
                    ";"
                }
            }
        }
    }
}
```

Note: The `leftPadding` utility may need to be verified — check if a `String` extension exists, or use `String(format: "%04X", offset)` instead if simpler.

**Step 3: Modify `semanticString(using:)` to prepend layout struct**

In the existing `ObjCClassInfo.semanticString(using:)` (line 22), prepend the ivar layout struct at the beginning:

```swift
extension ObjCClassInfo {
    @SemanticStringBuilder
    func semanticString(using context: ObjCDumpContext) -> SemanticString {
        if context.options.idaCompatible, !ivars.isEmpty {
            idaIvarLayoutStruct(using: context)
        }

        Keyword("@interface")
        Space()
        TypeDeclaration(kind: .class, name)
        // ... rest unchanged ...
    }
}
```

**Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Utils/ObjCDump+SemanticString.swift
git commit -m "feat(ida): generate __fixed/__at ivar layout structs for IDA Pro"
```

---

### Task 4: Add `.ida` preset to `GenerationOptions`

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface+GenerationOptions.swift`

**Step 1: Add static `.ida` preset**

After the existing `.mcp` preset (after line 41), add:

```swift
/// Options tuned for IDA Pro 9.3+: generates ivar layout structs,
/// strips comments that confuse IDA's Clang parser, collects IMP mappings.
public static let ida = GenerationOptions(
    objcHeaderOptions: ObjCGenerationOptions(
        stripProtocolConformance: false,
        stripOverrides: false,
        stripSynthesizedIvars: false,
        stripSynthesizedMethods: false,
        stripCtorMethod: true,
        stripDtorMethod: true,
        addIvarOffsetComments: false,
        addPropertyAttributesComments: false,
        addMethodIMPAddressComments: false,
        addPropertyAccessorAddressComments: false,
        idaCompatible: true
    )
)
```

**Step 2: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectInterface+GenerationOptions.swift
git commit -m "feat(ida): add .ida generation options preset"
```

---

### Task 5: Add `idaCompatible` to export configuration and writer

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportConfiguration.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportWriter.swift`
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift:506-586`

**Step 1: Add `idaCompatible` to `RuntimeInterfaceExportConfiguration`**

```swift
public struct RuntimeInterfaceExportConfiguration: Sendable {
    public enum Format: Int, Sendable {
        case singleFile = 0
        case directory = 1
    }

    public let imagePath: String
    public let imageName: String
    public let directory: URL
    public let objcFormat: Format
    public let swiftFormat: Format
    public let generationOptions: RuntimeObjectInterface.GenerationOptions
    public let idaCompatible: Bool

    public init(
        imagePath: String,
        imageName: String,
        directory: URL,
        objcFormat: Format,
        swiftFormat: Format,
        generationOptions: RuntimeObjectInterface.GenerationOptions,
        idaCompatible: Bool = false
    ) {
        self.imagePath = imagePath
        self.imageName = imageName
        self.directory = directory
        self.objcFormat = objcFormat
        self.swiftFormat = swiftFormat
        self.generationOptions = generationOptions
        self.idaCompatible = idaCompatible
    }
}
```

**Step 2: Add `.ida_map` writer to `RuntimeInterfaceExportWriter`**

```swift
static func writeIMPMappings(
    _ mappings: [RuntimeIMPMapping],
    to directory: URL,
    imageName: String
) throws {
    guard !mappings.isEmpty else { return }
    let sorted = mappings.sorted { $0.address < $1.address }
    var lines = [
        "# RuntimeViewer IDA IMP Mapping",
        "# Image: \(imageName)",
    ]
    for mapping in sorted {
        lines.append("\(mapping.address) \(mapping.selector)")
    }
    let content = lines.joined(separator: "\n") + "\n"
    let file = directory.appendingPathComponent("\(imageName).ida_map")
    try content.write(to: file, atomically: true, encoding: .utf8)
}
```

**Step 3: Modify `RuntimeEngine.exportInterfaces` to collect and write IMP mappings**

In `RuntimeEngine.exportInterfaces(with:reporter:)` (line 506), modify the export loop to collect IMP mappings, and after writing headers, write the `.ida_map` file:

```swift
// In the export loop (around line 528-545), collect impMappings:
var allIMPMappings: [RuntimeIMPMapping] = []

for (index, object) in allObjects.enumerated() {
    try Task.checkCancellation()
    reporter.send(.objectStarted(object, current: index + 1, total: total))
    do {
        guard let runtimeInterface = try await interface(for: object, options: configuration.generationOptions) else {
            throw RuntimeExportError.interfaceGenerationFailed(object)
        }
        let item = RuntimeInterfaceExportItem(
            object: object,
            plainText: runtimeInterface.interfaceString.string,
            suggestedFileName: object.exportFileName
        )
        results.append(item)
        succeeded += 1
        if item.isSwift { swiftCount += 1 } else { objcCount += 1 }

        if configuration.idaCompatible {
            allIMPMappings.append(contentsOf: runtimeInterface.impMappings)
        }

        reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
    } catch {
        failed += 1
        reporter.send(.objectFailed(object, error))
    }
}

// After writing ObjC/Swift files (after line 583), add:
if configuration.idaCompatible {
    try RuntimeInterfaceExportWriter.writeIMPMappings(
        allIMPMappings,
        to: configuration.directory,
        imageName: configuration.imageName
    )
}
```

**Step 4: Commit**

```bash
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportConfiguration.swift \
      RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportWriter.swift \
      RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat(ida): add .ida_map file generation and export pipeline integration"
```

---

### Task 6: Add UI controls (ExportingState, ViewModel, ViewController)

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingState.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewModel.swift`
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewController.swift`

**Step 1: Add `idaCompatible` to `ExportingState`**

After line 36 (`var currentStep`), add:

```swift
@Observed
var idaCompatible: Bool = false
```

**Step 2: Update `ExportingConfigurationViewModel`**

Add `idaCompatibleToggled` to `Input`:

```swift
struct Input {
    let objcFormatSelected: Signal<Int>
    let swiftFormatSelected: Signal<Int>
    let idaCompatibleToggled: Signal<Bool>
}
```

Add `idaCompatible` to `Output`:

```swift
struct Output {
    let objcCount: Driver<Int>
    let swiftCount: Driver<Int>
    let hasObjC: Driver<Bool>
    let hasSwift: Driver<Bool>
    let imageName: Driver<String>
    let objcFormat: Driver<ExportFormat>
    let swiftFormat: Driver<ExportFormat>
    let idaCompatible: Driver<Bool>
}
```

In `transform(_:)`, add binding and output:

```swift
input.idaCompatibleToggled.emitOnNext { [weak self] isOn in
    guard let self else { return }
    exportingState.idaCompatible = isOn
}
.disposed(by: rx.disposeBag)

return Output(
    // ... existing ...
    idaCompatible: exportingState.$idaCompatible.asDriver()
)
```

**Step 3: Update `ExportingConfigurationViewController`**

Add checkbox property (after line 15, the radio button declarations):

```swift
private let idaCompatibleCheckbox = CheckboxButton(title: "IDA Compatible")

private let idaCompatibleDesc = Label("Generate ivar layout structs and IMP mapping file for IDA Pro 9.3+").then {
    $0.font = .systemFont(ofSize: 11)
    $0.textColor = .tertiaryLabelColor
}
```

Add an `idaCompatibleStack` and insert into `objcStack`:

```swift
private lazy var idaCompatibleStack = VStackView(alignment: .leading, spacing: 4) {
    idaCompatibleCheckbox
    idaCompatibleDesc
}
```

Modify `objcStack` to include it:

```swift
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
    idaCompatibleStack
}
```

In `setupBindings(for:)`, update the `Input` construction:

```swift
let input = ExportingConfigurationViewModel.Input(
    objcFormatSelected: Signal.merge(
        objcSingleFileRadio.rx.click.asSignal().map { ExportFormat.singleFile.rawValue },
        objcDirectoryRadio.rx.click.asSignal().map { ExportFormat.directory.rawValue }
    ),
    swiftFormatSelected: Signal.merge(
        swiftSingleFileRadio.rx.click.asSignal().map { ExportFormat.singleFile.rawValue },
        swiftDirectoryRadio.rx.click.asSignal().map { ExportFormat.directory.rawValue }
    ),
    idaCompatibleToggled: idaCompatibleCheckbox.rx.click.asSignal().map { [weak self] in
        self?.idaCompatibleCheckbox.state == .on
    }
)
```

Add output binding after existing bindings:

```swift
output.idaCompatible.drive(idaCompatibleCheckbox.rx.isCheck).disposed(by: rx.disposeBag)
```

The `idaCompatibleStack` visibility is controlled by the existing `hasObjC` binding — since it's inside `objcStack`, it will be hidden/shown together with other ObjC options.

**Step 4: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingState.swift \
      RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewModel.swift \
      RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingConfigurationViewController.swift
git commit -m "feat(ida): add IDA Compatible checkbox to export configuration UI"
```

---

### Task 7: Wire `idaCompatible` through `ExportingProgressViewModel`

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewModel.swift:52-70`

**Step 1: Use IDA generation options when enabled**

In `startExport()`, modify the `generationOptions` and `configuration` construction:

```swift
func startExport() {
    if isExporting { return }
    isExporting = true
    guard let directory = exportingState.destinationURL else {
        isExporting = false
        return
    }

    var generationOptions: RuntimeObjectInterface.GenerationOptions
    if exportingState.idaCompatible {
        generationOptions = .ida
        generationOptions.transformer = settings.transformer
    } else {
        generationOptions = appDefaults.options
        generationOptions.transformer = settings.transformer
    }

    let configuration = RuntimeInterfaceExportConfiguration(
        imagePath: exportingState.imagePath,
        imageName: exportingState.imageName,
        directory: directory,
        objcFormat: exportingState.objcFormat,
        swiftFormat: exportingState.swiftFormat,
        generationOptions: generationOptions,
        idaCompatible: exportingState.idaCompatible
    )
    // ... rest unchanged ...
```

**Step 2: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Exporting/ExportingProgressViewModel.swift
git commit -m "feat(ida): wire idaCompatible through export progress to configuration"
```

---

### Task 8: Build and verify

**Step 1: Build the project**

Build using Xcode MCP `BuildProject` tool with scheme `RuntimeViewerUsingAppKit`.

**Step 2: Fix any compilation errors**

Address issues iteratively. Common potential issues:
- `leftPadding` may not exist on String — use `String(format: "0x%04X", offset)` instead
- `TypeDeclaration(kind: .struct, ...)` — verify `.struct` exists in the kind enum, may need `.class` or check `SemanticString` API
- `addressString(forOffset:)` — verify the exact API signature on `MachOImage`
- `ObjCCategoryInfo` — verify it has `className`/`categoryName` fields or adjust accordingly
- `rx.isCheck` — verify this binding exists for `CheckboxButton`

**Step 3: Commit final fixes**

```bash
git add -A
git commit -m "fix(ida): resolve compilation issues for IDA compatible export"
```

---

### Task 9: Update evolution proposal status

**Files:**
- Modify: `evolution/0001-ida-compatible-objc-export.md`

**Step 1: Update status to "Implemented"**

Change `- **Status**: Draft` to `- **Status**: Implemented` and update `Last Updated` date.

**Step 2: Commit**

```bash
git add evolution/0001-ida-compatible-objc-export.md
git commit -m "docs: update evolution 0001 status to Implemented"
```

---

## Task Dependency Graph

```
Task 1 (ObjCGenerationOptions) ──┐
                                  ├── Task 3 (ivar layout struct)
Task 2 (RuntimeIMPMapping)  ──────┤
                                  ├── Task 5 (export config + writer)
Task 4 (.ida preset)  ───────────┘         │
                                            │
Task 6 (UI controls)  ─────────────────────┤
                                            │
Task 7 (wire ProgressVM)  ←────────────────┘
                                            │
Task 8 (build + verify)  ←─────────────────┘
                                            │
Task 9 (update proposal)  ←────────────────┘
```

Tasks 1-2 can be done in parallel. Task 3 depends on Task 1. Task 4 depends on Task 1. Task 5 depends on Tasks 1+2. Task 6 is independent of core changes. Task 7 depends on Tasks 4+5+6. Task 8 depends on all. Task 9 is last.
