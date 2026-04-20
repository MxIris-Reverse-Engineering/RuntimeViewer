# Sidebar RuntimeObject Loading Progress Bar

## Summary

Replace the indeterminate spinner in `SidebarRuntimeObjectViewController`'s loading state with a determinate progress bar that shows real-time progress and descriptions of what content is being processed. Support both local and remote modes.

## Architecture Overview

```
MachOSwiftSection (add per-type events to indexTypes())
  ↓ SwiftInterfaceEvents
RuntimeViewerCore (ObjC progress via continuation, Swift via event handler, Engine stream API)
  ↓ AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>
RuntimeViewerApplication (ViewModel @Observed properties + stream consumption)
  ↓ Driver
RuntimeViewerUsingAppKit (NSProgressIndicator bar + description labels)
```

## Core Types

### RuntimeObjectsLoadingProgress (RuntimeViewerCore)

```swift
public struct RuntimeObjectsLoadingProgress: Sendable, Codable {
    public enum Phase: String, Sendable, Codable {
        case preparingObjCSection
        case loadingObjCClasses
        case loadingObjCProtocols
        case loadingObjCCategories
        case extractingSwiftTypes
        case extractingSwiftProtocols
        case extractingSwiftConformances
        case extractingSwiftAssociatedTypes
        case indexingSwiftTypes
        case indexingSwiftProtocols
        case indexingSwiftConformances
        case indexingSwiftExtensions
        case buildingObjects
    }
    
    public let phase: Phase
    public let itemDescription: String   // e.g. "NSView", "UIResponder"
    public let currentCount: Int
    public let totalCount: Int           // 0 = unknown
}
```

Codable for remote serialization over TCP.

### RuntimeObjectsLoadingEvent (RuntimeViewerCore)

```swift
public enum RuntimeObjectsLoadingEvent: Sendable {
    case progress(RuntimeObjectsLoadingProgress)
    case completed([RuntimeObject])
}
```

## Layer 1: MachOSwiftSection Changes

### New Events in SwiftInterfaceEvents.Payload

```swift
case typeProcessed(context: TypeContext)
case typeProcessingFailed(typeName: String, error: any Error)
case typeProcessingSkippedCImported(typeName: String)
case typeNestingResolved(context: TypeNestingContext)
```

### New Context Structs

```swift
public struct TypeContext: Sendable {
    public let typeName: String
    public let kind: String  // struct, class, enum, actor
}

public struct TypeNestingContext: Sendable {
    public let childTypeName: String
    public let parentTypeName: String?
}
```

### indexTypes() Dispatch Points

- First loop (TypeDefinition creation): dispatch `.typeProcessed` / `.typeProcessingFailed` / `.typeProcessingSkippedCImported` per item
- Second loop (nesting resolution): dispatch `.typeNestingResolved` per item

## Layer 2: RuntimeViewerCore Changes

### RuntimeObjCSection

Add optional continuation parameter to `init` and `prepare()`:

```swift
init(machO: MachOImage, factory: RuntimeObjCSectionFactory,
     progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation? = nil) async throws

private func prepare(
    progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation?
) async throws
```

In `prepare()`, yield progress in the three iteration loops:
- `for objcClass in objcClasses` → phase `.loadingObjCClasses`, itemDescription = class name
- `for objcProtocol in objcProtocols` → phase `.loadingObjCProtocols`
- `for objcCategory in objcCategories` → phase `.loadingObjCCategories`

### RuntimeSwiftSection

Create an internal handler that bridges SwiftInterfaceEvents to the continuation:

```swift
private final class ProgressEventHandler: SwiftInterfaceEvents.Handler, Sendable {
    let continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
    // Tracks currentCount per phase using atomics or Mutex
    
    func handle(event: SwiftInterfaceEvents.Payload) {
        // Map events to RuntimeObjectsLoadingProgress and yield
        // extractionStarted(.swiftTypes) → .extractingSwiftTypes
        // typeIndexingStarted(totalTypes:) → record total
        // typeProcessed → .indexingSwiftTypes, increment count
        // protocolProcessed → .indexingSwiftProtocols, increment count
        // conformanceFound → .indexingSwiftConformances, increment count
        // extensionCreated → .indexingSwiftExtensions, increment count
    }
}
```

Pass handler to indexer at init:

```swift
init(imagePath: String, factory: RuntimeSwiftSectionFactory,
     progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation? = nil) async throws {
    let eventHandlers: [SwiftInterfaceEvents.Handler] = 
        progressContinuation.map { [ProgressEventHandler(continuation: $0)] } ?? []
    self.indexer = .init(configuration: ..., eventHandlers: eventHandlers, in: machO)
    self.printer = .init(configuration: .init(), eventHandlers: [], in: machO)
    try await indexer.prepare()
}
```

### Factories

Add optional continuation parameter to `section(for:)`:

```swift
func section(for imagePath: String,
             progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation? = nil
) async throws -> (isExisted: Bool, section: RuntimeObjCSection)
```

When section is cached (`isExisted == true`), continuation is not used.

### RuntimeEngine

New public API:

```swift
public func objectsWithProgress(in image: String) -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
    AsyncThrowingStream { continuation in
        Task {
            do {
                let objects = try await request {
                    try await _objectsWithProgress(in: image, continuation: continuation)
                } remote: { [weak self] connection in
                    try await self?._remoteObjectsWithProgress(in: image, connection: connection, continuation: continuation) ?? []
                }
                continuation.yield(.completed(objects))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

Local implementation passes continuation through factories:

```swift
private func _objectsWithProgress(
    in image: String,
    continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
) async throws -> [RuntimeObject] {
    let image = DyldUtilities.patchImagePathForDyld(image)
    let (_, objcSection) = try await objcSectionFactory.section(for: image, progressContinuation: continuation)
    let objcObjects = try await objcSection.allObjects()
    let (_, swiftSection) = try await swiftSectionFactory.section(for: image, progressContinuation: continuation)
    let swiftObjects = try await swiftSection.allObjects()
    return objcObjects + swiftObjects
}
```

### Remote Mode

New command name:

```swift
case objectsLoadingProgress  // server → client push
```

Server side: `runtimeObjectsInImage` handler calls `_objectsWithProgress` and the continuation sends fire-and-forget progress pushes:

```swift
// In _remoteObjectsWithProgress on client side:
private func _remoteObjectsWithProgress(
    in image: String,
    connection: RuntimeConnection,
    continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
) async throws -> [RuntimeObject] {
    let subscription = objectsLoadingProgressSubject.sink { progress in
        continuation.yield(.progress(progress))
    }
    defer { subscription.cancel() }
    return try await connection.sendMessage(name: .runtimeObjectsInImage, request: image)
}
```

Server handler:

```swift
// Server registers handler for runtimeObjectsInImage that:
// 1. Creates a local continuation
// 2. On each progress yield, sends push: connection.sendMessage(name: .objectsLoadingProgress, request: progress)
// 3. Returns final [RuntimeObject] as the response
```

Client registers handler for `.objectsLoadingProgress`:

```swift
setMessageHandler(forName: .objectsLoadingProgress) { [weak self] (progress: RuntimeObjectsLoadingProgress) in
    self?.objectsLoadingProgressSubject.send(progress)
}
```

## Layer 3: RuntimeViewerApplication Changes

### SidebarRuntimeObjectViewModel

New properties:

```swift
@Observed public private(set) var loadingProgress: Double = 0
@Observed public private(set) var loadingDescription: String = ""
@Observed public private(set) var loadingItemCount: String = ""
```

New Output fields:

```swift
public let loadingProgress: Driver<Double>
public let loadingDescription: Driver<String>
public let loadingItemCount: Driver<String>
```

New overridable method:

```swift
func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
    // Default: wraps buildRuntimeObjects() with no progress
    AsyncThrowingStream { continuation in
        Task {
            do {
                let objects = try await buildRuntimeObjects()
                continuation.yield(.completed(objects))
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
}
```

Updated `reloadData()`:

```swift
func reloadData() async throws {
    let isLoaded = try await runtimeEngine.isImageLoaded(path: imagePath)
    if !isLoaded {
        await MainActor.run { self.loadState = .notLoaded }
        return
    }
    
    await MainActor.run {
        self.loadState = .loading
        self.loadingProgress = 0
        self.loadingDescription = "Preparing..."
        self.loadingItemCount = ""
    }
    
    var runtimeObjects: [RuntimeObject] = []
    for try await event in buildRuntimeObjectsStream() {
        switch event {
        case .progress(let progress):
            await MainActor.run {
                self.loadingProgress = progress.overallFraction
                self.loadingDescription = progress.phase.displayDescription
                self.loadingItemCount = progress.totalCount > 0
                    ? "\(progress.currentCount)/\(progress.totalCount)" : ""
            }
        case .completed(let result):
            runtimeObjects = result
        }
    }
    
    await MainActor.run {
        self.loadingProgress = 0.95
        self.loadingDescription = "Building list..."
        self.loadingItemCount = "\(runtimeObjects.count) objects"
    }
    
    let cellViewModels: [SidebarRuntimeObjectCellViewModel]
    if isSorted {
        cellViewModels = runtimeObjects.sorted().map { 
            SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false)
        }
    } else {
        cellViewModels = runtimeObjects.map {
            SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false)
        }
    }
    
    await MainActor.run {
        self.loadingProgress = 1.0
        self.loadState = .loaded
        self.searchString = ""
        self.nodes = cellViewModels
        self.filteredNodes = self.nodes
    }
}
```

### Phase Display Text & Progress Calculation

Extension on `RuntimeObjectsLoadingProgress.Phase`:

```swift
var displayDescription: String {
    switch self {
    case .preparingObjCSection: "Preparing Objective-C section..."
    case .loadingObjCClasses: "Loading Objective-C classes..."
    case .loadingObjCProtocols: "Loading Objective-C protocols..."
    case .loadingObjCCategories: "Loading Objective-C categories..."
    case .extractingSwiftTypes: "Extracting Swift types..."
    case .extractingSwiftProtocols: "Extracting Swift protocols..."
    case .extractingSwiftConformances: "Extracting Swift conformances..."
    case .extractingSwiftAssociatedTypes: "Extracting Swift associated types..."
    case .indexingSwiftTypes: "Indexing Swift types..."
    case .indexingSwiftProtocols: "Indexing Swift protocols..."
    case .indexingSwiftConformances: "Indexing Swift conformances..."
    case .indexingSwiftExtensions: "Indexing Swift extensions..."
    case .buildingObjects: "Building objects..."
    }
}
```

Overall fraction calculation: each phase maps to a fixed segment of 0.0-1.0:

| Phase group | Range |
|---|---|
| ObjC (preparing + classes + protocols + categories) | 0.0 - 0.45 |
| Swift extraction (4 phases) | 0.45 - 0.55 |
| Swift indexing (4 phases) | 0.55 - 0.90 |
| Building objects | 0.90 - 1.0 |

Within each phase, progress is `currentCount / totalCount`.

### SidebarRuntimeObjectListViewModel

```swift
override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
    runtimeEngine.objectsWithProgress(in: imagePath)
}
```

### SidebarRuntimeObjectBookmarkViewModel

No changes. Uses default `buildRuntimeObjectsStream()` which wraps `buildRuntimeObjects()` with instant `.completed`.

## Layer 4: RuntimeViewerUsingAppKit Changes

### ImageLoadingView Redesign

Centered compact layout:

```
         ┌──────────────────────────┐
         │ ████████████░░░░░░░░░░░░ │   ← NSProgressIndicator (bar, determinate), width 260
         └──────────────────────────┘
         Loading Objective-C classes...  ← descriptionLabel (secondaryLabelColor, 12pt)
                  142/1500               ← countLabel (tertiaryLabelColor, 11pt monospaced digits)
```

```swift
final class ImageLoadingView: XiblessView {
    let progressIndicator = NSProgressIndicator()
    let descriptionLabel = Label()
    let countLabel = Label()
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        let contentStack = VStackView(alignment: .vStackCenter, spacing: 8) {
            progressIndicator
            descriptionLabel
            countLabel
        }
        
        hierarchy { contentStack }
        
        contentStack.snp.makeConstraints { make in
            make.center.equalToSuperview()
        }
        
        progressIndicator.snp.makeConstraints { make in
            make.width.equalTo(260)
        }
        
        progressIndicator.do {
            $0.style = .bar
            $0.isIndeterminate = false
            $0.minValue = 0
            $0.maxValue = 1
        }
        
        descriptionLabel.do {
            $0.textColor = .secondaryLabelColor
            $0.font = .systemFont(ofSize: 12)
            $0.alignment = .center
        }
        
        countLabel.do {
            $0.textColor = .tertiaryLabelColor
            $0.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            $0.alignment = .center
        }
    }
}
```

### Bindings in SidebarRuntimeObjectViewController.setupBindings

```swift
output.loadingProgress.drive(imageLoadingView.progressIndicator.rx.doubleValue)
    .disposed(by: rx.disposeBag)

output.loadingDescription.drive(imageLoadingView.descriptionLabel.rx.stringValue)
    .disposed(by: rx.disposeBag)

output.loadingItemCount.drive(imageLoadingView.countLabel.rx.stringValue)
    .disposed(by: rx.disposeBag)
```

The existing 500ms delay on `.loading` state transition is preserved — fast loads still skip the loading page entirely.

## What Does NOT Change

- `SidebarRuntimeObjectBookmarkViewModel` — bookmarks load instantly, no progress needed
- `RuntimeViewerCommunication` protocol layer — zero changes, reuses existing fire-and-forget push mechanism
- `allObjects()` methods — lightweight dictionary-to-array mapping, no progress needed
- Original `objects(in:)` API on RuntimeEngine — preserved for callers that don't need progress
