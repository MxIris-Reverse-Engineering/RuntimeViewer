# Sidebar Loading Progress Bar — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the indeterminate spinner in Sidebar RuntimeObject's loading state with a determinate progress bar that reports fine-grained per-item progress across ObjC/Swift section preparation, with support for both local and remote modes.

**Architecture:** Bottom-up: MachOSwiftSection adds per-type events → RuntimeViewerCore adds `RuntimeObjectsLoadingProgress` model, wires ObjC progress via continuation, Swift via event handler, exposes `objectsWithProgress(in:)` returning `AsyncThrowingStream` → RuntimeViewerApplication ViewModel consumes stream → AppKit VC shows `NSProgressIndicator` bar with description labels.

**Tech Stack:** Swift 5 (swiftLanguageModes: [.v5]), RxSwift, AsyncThrowingStream, SwiftInterfaceEvents, SnapKit, AppKit

---

## File Map

| Action | File | Responsibility |
|--------|------|---------------|
| Modify | `MachOSwiftSection: Sources/SwiftInterface/SwiftInterfaceEvents.swift` | Add per-type event cases + context structs |
| Modify | `MachOSwiftSection: Sources/SwiftInterface/SwiftInterfaceIndexer.swift` | Dispatch per-type events in `indexTypes()` |
| Create | `RuntimeViewerCore: Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift` | Progress model + event enum |
| Modify | `RuntimeViewerCore: Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift` | Accept continuation, yield per-item progress in `prepare()` |
| Modify | `RuntimeViewerCore: Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift` | ProgressEventHandler bridging SwiftInterfaceEvents → continuation |
| Modify | `RuntimeViewerCore: Sources/RuntimeViewerCore/RuntimeEngine.swift` | `objectsWithProgress(in:)` API, remote progress push, new CommandNames case |
| Modify | `RuntimeViewerPackages: Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift` | New @Observed properties, `buildRuntimeObjectsStream()`, updated `reloadData()` |
| Modify | `RuntimeViewerPackages: Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift` | Override `buildRuntimeObjectsStream()` |
| Modify | `RuntimeViewerUsingAppKit: RuntimeViewerUsingAppKit/Sidebar/SidebarRuntimeObjectViewController.swift` | Redesign ImageLoadingView, add bindings |

---

### Task 1: Add Per-Type Events to MachOSwiftSection

**Files:**
- Modify: `/Volumes/Code/Personal/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceEvents.swift`
- Modify: `/Volumes/Code/Personal/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceIndexer.swift`

- [ ] **Step 1: Add new context structs and event cases to `SwiftInterfaceEvents`**

In `/Volumes/Code/Personal/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceEvents.swift`, add the new context structs before the closing `}` of `SwiftInterfaceEvents` (after `PrintingDefinitionKind`):

```swift
public struct TypeContext: Sendable {
    public let typeName: String
    public let kind: TypeKind
}

public struct TypeNestingContext: Sendable {
    public let childTypeName: String
    public let parentTypeName: String?
}
```

Add the new event cases inside the `Payload` enum, after the existing `case typeIndexingCompleted(result: TypeIndexingResult)` line:

```swift
case typeProcessed(context: TypeContext)
case typeProcessingFailed(typeName: String?, error: any Error)
case typeProcessingSkippedCImported
case typeNestingResolved(context: TypeNestingContext)
```

- [ ] **Step 2: Dispatch per-type events in `indexTypes()` first loop**

In `/Volumes/Code/Personal/MachOSwiftSection/Sources/SwiftInterface/SwiftInterfaceIndexer.swift`, in the `indexTypes()` method, modify the first `for type in currentStorage.types` loop (lines 250-263) to dispatch events:

Replace:
```swift
        for type in currentStorage.types {
            if let isCImportedContext = try? type.contextDescriptorWrapper.contextDescriptor.isCImportedContextDescriptor(in: machO), !configuration.showCImportedTypes, isCImportedContext {
                cImportedCount += 1
                continue
            }

            do {
                let declaration = try await TypeDefinition(type: type, in: machO)
                currentModuleTypeDefinitions[declaration.typeName] = declaration
                successfulCount += 1
            } catch {
                failedCount += 1
            }
        }
```

With:
```swift
        for type in currentStorage.types {
            if let isCImportedContext = try? type.contextDescriptorWrapper.contextDescriptor.isCImportedContextDescriptor(in: machO), !configuration.showCImportedTypes, isCImportedContext {
                cImportedCount += 1
                eventDispatcher.dispatch(.typeProcessingSkippedCImported)
                continue
            }

            do {
                let declaration = try await TypeDefinition(type: type, in: machO)
                currentModuleTypeDefinitions[declaration.typeName] = declaration
                successfulCount += 1
                eventDispatcher.dispatch(.typeProcessed(context: SwiftInterfaceEvents.TypeContext(typeName: declaration.typeName.name, kind: declaration.typeName.kind)))
            } catch {
                let typeName = try? type.typeName(in: machO)
                failedCount += 1
                eventDispatcher.dispatch(.typeProcessingFailed(typeName: typeName?.name, error: error))
            }
        }
```

- [ ] **Step 3: Dispatch per-type nesting events in `indexTypes()` second loop**

In the same method, modify the second `for type in currentStorage.types` loop (lines 268-298) to dispatch nesting events. Add after the `parentLoop: while` block closes (before the closing `}` of the for loop):

After the `parentLoop:` while block, the type either found a parent or is a root. We dispatch after the while exits. Replace the entire second for loop:

```swift
        for type in currentStorage.types {
            guard let typeName = try? type.typeName(in: machO), let childDefinition = currentModuleTypeDefinitions[typeName] else {
                continue
            }

            var parentContext = try ContextWrapper.type(type).parent(in: machO)
            var resolvedParentName: String?

            parentLoop: while let currentContextOrSymbol = parentContext {
                switch currentContextOrSymbol {
                case .symbol(let symbol):
                    childDefinition.parentContext = .symbol(symbol)
                    break parentLoop
                case .element(let currentContext):
                    if case .type(let typeContext) = currentContext, let parentTypeName = try? typeContext.typeName(in: machO) {
                        if let parentDefinition = currentModuleTypeDefinitions[parentTypeName] {
                            childDefinition.parent = parentDefinition
                            parentDefinition.typeChildren.append(childDefinition)
                            resolvedParentName = parentTypeName.name
                        } else {
                            childDefinition.parentContext = .type(typeContext)
                            resolvedParentName = parentTypeName.name
                        }
                        nestedTypeCount += 1
                        break parentLoop
                    } else if case .extension(let extensionContext) = currentContext {
                        childDefinition.parentContext = .extension(extensionContext)
                        extensionTypeCount += 1
                        break parentLoop
                    }
                    parentContext = try currentContext.parent(in: machO)
                }
            }

            eventDispatcher.dispatch(.typeNestingResolved(context: SwiftInterfaceEvents.TypeNestingContext(childTypeName: typeName.name, parentTypeName: resolvedParentName)))
        }
```

- [ ] **Step 4: Build MachOSwiftSection to verify compilation**

```bash
cd /Volumes/Code/Personal/MachOSwiftSection && swift build 2>&1 | head -30
```

Expected: Build succeeds with no errors.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Code/Personal/MachOSwiftSection
git add Sources/SwiftInterface/SwiftInterfaceEvents.swift Sources/SwiftInterface/SwiftInterfaceIndexer.swift
git commit -m "feat: add per-type dispatch events to indexTypes() for progress reporting"
```

---

### Task 2: Create RuntimeObjectsLoadingProgress Model

**Files:**
- Create: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift`

- [ ] **Step 1: Create the progress model file**

Create `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift`:

```swift
import Foundation

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
    public let itemDescription: String
    public let currentCount: Int
    public let totalCount: Int

    public init(phase: Phase, itemDescription: String, currentCount: Int, totalCount: Int) {
        self.phase = phase
        self.itemDescription = itemDescription
        self.currentCount = currentCount
        self.totalCount = totalCount
    }
}

public enum RuntimeObjectsLoadingEvent: Sendable {
    case progress(RuntimeObjectsLoadingProgress)
    case completed([RuntimeObject])
}

// MARK: - Phase Display

extension RuntimeObjectsLoadingProgress.Phase {
    public var displayDescription: String {
        switch self {
        case .preparingObjCSection: return "Preparing Objective-C section..."
        case .loadingObjCClasses: return "Loading Objective-C classes..."
        case .loadingObjCProtocols: return "Loading Objective-C protocols..."
        case .loadingObjCCategories: return "Loading Objective-C categories..."
        case .extractingSwiftTypes: return "Extracting Swift types..."
        case .extractingSwiftProtocols: return "Extracting Swift protocols..."
        case .extractingSwiftConformances: return "Extracting Swift conformances..."
        case .extractingSwiftAssociatedTypes: return "Extracting Swift associated types..."
        case .indexingSwiftTypes: return "Indexing Swift types..."
        case .indexingSwiftProtocols: return "Indexing Swift protocols..."
        case .indexingSwiftConformances: return "Indexing Swift conformances..."
        case .indexingSwiftExtensions: return "Indexing Swift extensions..."
        case .buildingObjects: return "Building objects..."
        }
    }

    /// The fixed range [start, end) within the overall 0.0–1.0 progress for each phase.
    public var progressRange: (start: Double, end: Double) {
        switch self {
        // ObjC phases: 0.0 – 0.45
        case .preparingObjCSection:          return (0.00, 0.02)
        case .loadingObjCClasses:            return (0.02, 0.25)
        case .loadingObjCProtocols:          return (0.25, 0.35)
        case .loadingObjCCategories:         return (0.35, 0.45)
        // Swift extraction phases: 0.45 – 0.55
        case .extractingSwiftTypes:          return (0.45, 0.48)
        case .extractingSwiftProtocols:      return (0.48, 0.50)
        case .extractingSwiftConformances:   return (0.50, 0.52)
        case .extractingSwiftAssociatedTypes: return (0.52, 0.55)
        // Swift indexing phases: 0.55 – 0.90
        case .indexingSwiftTypes:            return (0.55, 0.72)
        case .indexingSwiftProtocols:        return (0.72, 0.80)
        case .indexingSwiftConformances:     return (0.80, 0.87)
        case .indexingSwiftExtensions:       return (0.87, 0.90)
        // Building: 0.90 – 1.0
        case .buildingObjects:              return (0.90, 1.00)
        }
    }
}

extension RuntimeObjectsLoadingProgress {
    /// Overall fraction from 0.0 to 1.0 combining phase range and item progress within that phase.
    public var overallFraction: Double {
        let range = phase.progressRange
        let phaseWidth = range.end - range.start
        if totalCount > 0 {
            let itemFraction = Double(currentCount) / Double(totalCount)
            return range.start + phaseWidth * itemFraction
        } else {
            return range.start
        }
    }
}
```

- [ ] **Step 2: Build RuntimeViewerCore to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObjectsLoadingProgress.swift
git commit -m "feat: add RuntimeObjectsLoadingProgress model and RuntimeObjectsLoadingEvent enum"
```

---

### Task 3: Add Progress Continuation to RuntimeObjCSection

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift`

- [ ] **Step 1: Add typealias for readability**

At the top of the file (after imports), add:

```swift
typealias LoadingEventContinuation = AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
```

- [ ] **Step 2: Modify `RuntimeObjCSection` inits to accept continuation**

There are two `init` methods. Add `progressContinuation` parameter to both:

Modify the `init(imagePath:factory:)` init (around line 112):

```swift
    init(imagePath: String, factory: RuntimeObjCSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section for: \(imagePath, privacy: .public)")
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else {
            #log(.error, "Failed to create MachOImage for: \(imageName, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.machO = machO
        self.imagePath = imagePath
        self.factory = factory
        try await prepare(progressContinuation: progressContinuation)
    }
```

Modify the `init(machO:factory:)` init (around line 122):

```swift
    init(machO: MachOImage, factory: RuntimeObjCSectionFactory, progressContinuation: LoadingEventContinuation? = nil) async throws {
        #log(.info, "Initializing ObjC section from MachO: \(machO.imagePath, privacy: .public)")
        self.machO = machO
        self.imagePath = machO.imagePath
        self.factory = factory
        try await prepare(progressContinuation: progressContinuation)
    }
```

- [ ] **Step 3: Add progress yielding to `prepare()`**

Modify the `prepare()` method signature to accept the continuation:

```swift
    private func prepare(progressContinuation: LoadingEventContinuation? = nil) async throws {
```

In the method body, add yields to the three iteration loops.

After the `objcClasses` array is built (line 193), before the loop starts, yield the preparing phase:

```swift
        let objcClasses: [any ObjCClassProtocol] = machO.objc.classes64.orEmpty + machO.objc.classes32.orEmpty + machO.objc.nonLazyClasses64.orEmpty + machO.objc.nonLazyClasses32.orEmpty

        let totalObjCClassCount = objcClasses.count
```

In the `for objcClass in objcClasses` loop, after `classByName[objcClassInfo.name] = objcClassGroup`, add:

```swift
            progressContinuation?.yield(.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCClasses,
                itemDescription: objcClassInfo.name,
                currentCount: classByName.count,
                totalCount: totalObjCClassCount
            )))
```

For the protocols loop, after `protocolByName[objcProtocolInfo.name] = (objcProtocol, objcProtocolInfo)`, add:

```swift
            progressContinuation?.yield(.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCProtocols,
                itemDescription: objcProtocolInfo.name,
                currentCount: protocolByName.count,
                totalCount: objcProtocols.count
            )))
```

For the categories loop, after `categoryByName[objcCategoryInfo.uniqueName] = (objcCategory, objcCategoryInfo)`, add:

```swift
            progressContinuation?.yield(.progress(RuntimeObjectsLoadingProgress(
                phase: .loadingObjCCategories,
                itemDescription: objcCategoryInfo.uniqueName,
                currentCount: categoryByName.count,
                totalCount: objcCategories.count
            )))
```

- [ ] **Step 4: Update `RuntimeObjCSectionFactory.section(for:)` methods**

Modify both `section(for:)` methods to pass through the continuation:

```swift
    func section(for imagePath: String, progressContinuation: LoadingEventContinuation? = nil) async throws -> (isExisted: Bool, section: RuntimeObjCSection) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached ObjC section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        #log(.debug, "Creating ObjC section for: \(imagePath, privacy: .public)")
        let section = try await RuntimeObjCSection(imagePath: imagePath, factory: self, progressContinuation: progressContinuation)
        sections[imagePath] = section
        #log(.debug, "ObjC section created and cached")
        return (false, section)
    }
```

The second `section(for name:)` variant does not need progress (it's used for individual class/protocol lookups, not bulk loading).

- [ ] **Step 5: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20
```

Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeObjCSection.swift
git commit -m "feat: add progress continuation to RuntimeObjCSection for per-item loading progress"
```

---

### Task 4: Add Progress Event Handler to RuntimeSwiftSection

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift`

- [ ] **Step 1: Add ProgressEventHandler class inside RuntimeSwiftSection**

Add this as a private nested type inside the `RuntimeSwiftSection` actor (after the `InterfaceDefinitionName` enum):

```swift
    private final class ProgressEventHandler: SwiftInterfaceEvents.Handler, @unchecked Sendable {
        let continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation

        private struct PhaseState {
            var currentCount: Int = 0
            var totalCount: Int = 0
        }

        private let lock = NSLock()
        private var phaseStates: [RuntimeObjectsLoadingProgress.Phase: PhaseState] = [:]

        init(continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation) {
            self.continuation = continuation
        }

        func handle(event: SwiftInterfaceEvents.Payload) {
            switch event {
            // Extraction events
            case .extractionStarted(let section):
                let phase = extractionPhase(for: section)
                if let phase {
                    yieldProgress(phase: phase, itemDescription: "", currentCount: 0, totalCount: 0)
                }

            // Type indexing
            case .typeIndexingStarted(let totalTypes):
                lock.withLock { phaseStates[.indexingSwiftTypes] = PhaseState(currentCount: 0, totalCount: totalTypes) }
            case .typeProcessed(let context):
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: context.typeName)
            case .typeProcessingFailed:
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: "")
            case .typeProcessingSkippedCImported:
                incrementAndYield(phase: .indexingSwiftTypes, itemDescription: "")

            // Protocol indexing
            case .protocolIndexingStarted(let totalProtocols):
                lock.withLock { phaseStates[.indexingSwiftProtocols] = PhaseState(currentCount: 0, totalCount: totalProtocols) }
            case .protocolProcessed(let context):
                incrementAndYield(phase: .indexingSwiftProtocols, itemDescription: context.protocolName)
            case .protocolProcessingFailed:
                incrementAndYield(phase: .indexingSwiftProtocols, itemDescription: "")

            // Conformance indexing
            case .conformanceIndexingStarted(let input):
                lock.withLock { phaseStates[.indexingSwiftConformances] = PhaseState(currentCount: 0, totalCount: input.totalConformances) }
            case .conformanceFound(let context):
                incrementAndYield(phase: .indexingSwiftConformances, itemDescription: "\(context.typeName): \(context.protocolName)")
            case .conformanceProcessingFailed:
                incrementAndYield(phase: .indexingSwiftConformances, itemDescription: "")

            // Extension indexing
            case .extensionIndexingStarted:
                lock.withLock { phaseStates[.indexingSwiftExtensions] = PhaseState(currentCount: 0, totalCount: 0) }
            case .extensionCreated(let context):
                incrementAndYield(phase: .indexingSwiftExtensions, itemDescription: context.targetName)
            case .extensionCreationFailed:
                incrementAndYield(phase: .indexingSwiftExtensions, itemDescription: "")

            default:
                break
            }
        }

        private func extractionPhase(for section: SwiftInterfaceEvents.Section) -> RuntimeObjectsLoadingProgress.Phase? {
            switch section {
            case .swiftTypes: return .extractingSwiftTypes
            case .swiftProtocols: return .extractingSwiftProtocols
            case .protocolConformances: return .extractingSwiftConformances
            case .associatedTypes: return .extractingSwiftAssociatedTypes
            }
        }

        private func incrementAndYield(phase: RuntimeObjectsLoadingProgress.Phase, itemDescription: String) {
            let state: PhaseState = lock.withLock {
                phaseStates[phase, default: PhaseState()].currentCount += 1
                return phaseStates[phase, default: PhaseState()]
            }
            yieldProgress(phase: phase, itemDescription: itemDescription, currentCount: state.currentCount, totalCount: state.totalCount)
        }

        private func yieldProgress(phase: RuntimeObjectsLoadingProgress.Phase, itemDescription: String, currentCount: Int, totalCount: Int) {
            continuation.yield(.progress(RuntimeObjectsLoadingProgress(
                phase: phase,
                itemDescription: itemDescription,
                currentCount: currentCount,
                totalCount: totalCount
            )))
        }
    }
```

- [ ] **Step 2: Modify RuntimeSwiftSection init to accept and use continuation**

Modify the `init(imagePath:factory:)` at line 82:

```swift
    init(imagePath: String, factory: RuntimeSwiftSectionFactory, progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation? = nil) async throws {
        #log(.info, "Initializing Swift section for image: \(imagePath, privacy: .public)")
        let imageName = imagePath.lastPathComponent.deletingPathExtension.deletingPathExtension
        guard let machO = MachOImage(name: imageName) else {
            #log(.error, "Failed to create MachOImage for: \(imageName, privacy: .public)")
            throw Error.invalidMachOImage
        }
        self.factory = factory
        self.imagePath = imagePath
        self.machO = machO
        #log(.debug, "Creating Swift Interface Components")
        let eventHandlers: [SwiftInterfaceEvents.Handler] = progressContinuation.map { [ProgressEventHandler(continuation: $0)] } ?? []
        self.indexer = .init(configuration: .init(showCImportedTypes: false), eventHandlers: eventHandlers, in: machO)
        self.printer = .init(configuration: .init(), eventHandlers: [], in: machO)
        try await indexer.prepare()
        #log(.info, "Swift section initialized successfully")
    }
```

- [ ] **Step 3: Update RuntimeSwiftSectionFactory.section(for:)**

Modify at line 670:

```swift
    func section(for imagePath: String, progressContinuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation? = nil) async throws -> (isExisted: Bool, section: RuntimeSwiftSection) {
        if let section = sections[imagePath] {
            #log(.debug, "Using cached Swift section for: \(imagePath, privacy: .public)")
            return (true, section)
        }
        #log(.debug, "Creating Swift section for: \(imagePath, privacy: .public)")
        let section = try await RuntimeSwiftSection(imagePath: imagePath, factory: self, progressContinuation: progressContinuation)
        sections[imagePath] = section
        #log(.debug, "Swift section created and cached")
        return (false, section)
    }
```

- [ ] **Step 4: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20
```

Expected: Build succeeds.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerCore/Sources/RuntimeViewerCore/Core/RuntimeSwiftSection.swift
git commit -m "feat: add ProgressEventHandler bridging SwiftInterfaceEvents to loading progress continuation"
```

---

### Task 5: Add `objectsWithProgress(in:)` to RuntimeEngine (Local Mode)

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

- [ ] **Step 1: Add `objectsLoadingProgress` to CommandNames enum**

In the `CommandNames` enum (line 49), add after `case engineListChanged`:

```swift
        case objectsLoadingProgress
```

- [ ] **Step 2: Add the public `objectsWithProgress(in:)` method**

Add after the existing `objects(in:)` method (after line 521):

```swift
    public func objectsWithProgress(in image: String) -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects: [RuntimeObject]
                    if let remoteRole = await self.source.remoteRole, remoteRole.isClient {
                        objects = try await self._remoteObjectsWithProgress(in: image, continuation: continuation)
                    } else {
                        objects = try await self._localObjectsWithProgress(in: image, continuation: continuation)
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

- [ ] **Step 3: Add `_localObjectsWithProgress` private method**

Add after the new method:

```swift
    private func _localObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
    ) async throws -> [RuntimeObject] {
        #log(.debug, "Getting objects with progress in image: \(image, privacy: .public)")
        let image = DyldUtilities.patchImagePathForDyld(image)
        let (isObjCSectionExisted, objcSection) = try await objcSectionFactory.section(for: image, progressContinuation: continuation)
        let objcObjects = try await objcSection.allObjects()
        let (isSwiftSectionExisted, swiftSection) = try await swiftSectionFactory.section(for: image, progressContinuation: continuation)
        let swiftObjects = try await swiftSection.allObjects()
        if !isObjCSectionExisted || !isSwiftSectionExisted {
            loadedImagePaths.insert(image)
        }
        #log(.debug, "Found \(objcObjects.count, privacy: .public) ObjC and \(swiftObjects.count, privacy: .public) Swift objects with progress")
        return objcObjects + swiftObjects
    }
```

- [ ] **Step 4: Add placeholder `_remoteObjectsWithProgress` (will be completed in Task 6)**

```swift
    private func _remoteObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
    ) async throws -> [RuntimeObject] {
        // Remote progress support will be wired in Task 6.
        // For now, fall back to the existing non-progress path.
        guard let connection else { throw RequestError.senderConnectionIsLose }
        return try await connection.sendMessage(name: .runtimeObjectsInImage, request: image)
    }
```

- [ ] **Step 5: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20
```

Expected: Build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add objectsWithProgress(in:) AsyncThrowingStream API to RuntimeEngine"
```

---

### Task 6: Add Remote Progress Support to RuntimeEngine

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift`

- [ ] **Step 1: Add `objectsLoadingProgressSubject` property**

In the `RuntimeEngine` actor, in the "Data Properties" section (after `reloadDataSubject` at line 142), add:

```swift
    private nonisolated let objectsLoadingProgressSubject = PassthroughSubject<RuntimeObjectsLoadingProgress, Never>()
```

- [ ] **Step 2: Register client handler for progress pushes**

In `setupMessageHandlerForClient()` (line 290), add after the `.reloadData` handler:

```swift
        setMessageHandlerBinding(forName: .objectsLoadingProgress) { $0.objectsLoadingProgressSubject.send($1) }
```

- [ ] **Step 3: Modify server handler for `runtimeObjectsInImage` to send progress pushes**

In `setupMessageHandlerForServer()` (line 271), replace the existing handler registration:

```swift
        setMessageHandlerBinding(forName: .runtimeObjectsInImage, of: self) { $0.objects(in:) }
```

With:

```swift
        connection.setMessageHandler(name: CommandNames.runtimeObjectsInImage.commandName) { [weak self] (imagePath: String) -> [RuntimeObject] in
            guard let self else { throw RequestError.senderConnectionIsLose }
            return try await self._serverObjectsWithProgress(in: imagePath)
        }
```

- [ ] **Step 4: Add `_serverObjectsWithProgress` method**

Add this to the engine:

```swift
    private func _serverObjectsWithProgress(in image: String) async throws -> [RuntimeObject] {
        let progressStream = objectsWithProgress(in: image)
        var result: [RuntimeObject] = []
        for try await event in progressStream {
            switch event {
            case .progress(let progress):
                try? await connection?.sendMessage(name: .objectsLoadingProgress, request: progress)
            case .completed(let objects):
                result = objects
            }
        }
        return result
    }
```

- [ ] **Step 5: Complete `_remoteObjectsWithProgress` implementation**

Replace the placeholder from Task 5:

```swift
    private func _remoteObjectsWithProgress(
        in image: String,
        continuation: AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error>.Continuation
    ) async throws -> [RuntimeObject] {
        guard let connection else { throw RequestError.senderConnectionIsLose }
        let cancellable = objectsLoadingProgressSubject.sink { progress in
            continuation.yield(.progress(progress))
        }
        defer { cancellable.cancel() }
        return try await connection.sendMessage(name: .runtimeObjectsInImage, request: image)
    }
```

- [ ] **Step 6: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | head -20
```

Expected: Build succeeds.

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift
git commit -m "feat: add remote progress push support for objectsWithProgress"
```

---

### Task 7: Update SidebarRuntimeObjectViewModel with Progress Properties and Stream

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift`

- [ ] **Step 1: Add new @Observed properties**

After the existing `@Observed` properties (line 23), add:

```swift
    @Observed public private(set) var loadingProgress: Double = 0
    @Observed public private(set) var loadingDescription: String = ""
    @Observed public private(set) var loadingItemCount: String = ""
```

- [ ] **Step 2: Add new Output fields**

In the `Output` struct, add after `isEmpty`:

```swift
        public let loadingProgress: Driver<Double>
        public let loadingDescription: Driver<String>
        public let loadingItemCount: Driver<String>
```

- [ ] **Step 3: Wire new outputs in `transform()`**

In the `return Output(...)` block (line 140), add the three new fields after `isEmpty`:

```swift
            loadingProgress: $loadingProgress.asDriver(),
            loadingDescription: $loadingDescription.asDriver(),
            loadingItemCount: $loadingItemCount.asDriver(),
```

- [ ] **Step 4: Add `buildRuntimeObjectsStream()` method**

After `buildRuntimeObjects()` (line 183), add:

```swift
    func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { continuation in
            Task { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let objects = try await self.buildRuntimeObjects()
                    continuation.yield(.completed(objects))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
```

- [ ] **Step 5: Replace `reloadData()` with progress-aware version**

Replace the entire `reloadData()` method (lines 155-181):

```swift
    func reloadData() async throws {
        let imageLoadState: RuntimeImageLoadState = try await runtimeEngine.isImageLoaded(path: imagePath) ? .loaded : .notLoaded

        if case .notLoaded = imageLoadState {
            await MainActor.run {
                self.loadState = .notLoaded
            }
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
                    if progress.totalCount > 0 {
                        self.loadingItemCount = "\(progress.currentCount)/\(progress.totalCount)"
                    } else {
                        self.loadingItemCount = ""
                    }
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

        await MainActor.run {
            self.loadState = .loaded
            self.loadingProgress = 1.0
            self.searchString = ""
            if isSorted {
                self.nodes = runtimeObjects.sorted().map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            } else {
                self.nodes = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
            }
            self.filteredNodes = self.nodes
        }
    }
```

- [ ] **Step 6: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerPackages && swift build 2>&1 | head -30
```

Expected: Build succeeds (or only downstream targets fail, which is OK).

- [ ] **Step 7: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectViewModel.swift
git commit -m "feat: add loading progress properties and stream-based reloadData to SidebarRuntimeObjectViewModel"
```

---

### Task 8: Override `buildRuntimeObjectsStream()` in SidebarRuntimeObjectListViewModel

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift`

- [ ] **Step 1: Add stream override**

After the existing `buildRuntimeObjects()` override (line 30-32), add:

```swift
    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        runtimeEngine.objectsWithProgress(in: imagePath)
    }
```

- [ ] **Step 2: Build to verify**

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerPackages && swift build 2>&1 | head -30
```

Expected: Build succeeds.

- [ ] **Step 3: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerApplication/Sidebar/SidebarRuntimeObjectListViewModel.swift
git commit -m "feat: override buildRuntimeObjectsStream in list VM to use engine progress API"
```

---

### Task 9: Redesign ImageLoadingView and Add Bindings

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Sidebar/SidebarRuntimeObjectViewController.swift`

- [ ] **Step 1: Replace ImageLoadingView implementation**

Replace the entire `ImageLoadingView` class (lines 221-243) with:

```swift
    final class ImageLoadingView: XiblessView {
        let progressIndicator = NSProgressIndicator()
        let descriptionLabel = Label()
        let countLabel = Label()

        override init(frame frameRect: CGRect) {
            super.init(frame: frameRect)

            let contentStack = VStackView(alignment: .vStackCenter, spacing: 8) {
                progressIndicator
                descriptionLabel
                countLabel
            }

            hierarchy {
                contentStack
            }

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
                $0.doubleValue = 0
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

- [ ] **Step 2: Add progress bindings in `setupBindings(for:)`**

In `setupBindings(for:)`, after the existing `output.loadState` binding (line 176), add:

```swift
        output.loadingProgress.driveOnNextMainActor { [weak self] progress in
            guard let self else { return }
            imageLoadingView.progressIndicator.doubleValue = progress
        }
        .disposed(by: rx.disposeBag)

        output.loadingDescription.drive(imageLoadingView.descriptionLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)

        output.loadingItemCount.drive(imageLoadingView.countLabel.rx.stringValue)
            .disposed(by: rx.disposeBag)
```

Note: Using `driveOnNextMainActor` for the progress indicator to ensure `doubleValue` is set on the main thread, since `NSProgressIndicator` does not have a built-in `rx.doubleValue` binder.

- [ ] **Step 3: Build the full project to verify end-to-end**

```bash
cd /Volumes/Code/Personal/RuntimeViewer && xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -20
```

Expected: Build succeeds.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Sidebar/SidebarRuntimeObjectViewController.swift
git commit -m "feat: replace indeterminate spinner with determinate progress bar and description labels"
```

---

### Task 10: Update MachOSwiftSection Dependency and Final Verification

**Files:**
- Modify: `/Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore/Package.swift` (if needed to pick up MachOSwiftSection changes)

- [ ] **Step 1: Update MachOSwiftSection dependency**

If MachOSwiftSection is a local path dependency, push changes to the MachOSwiftSection repo first:

```bash
cd /Volumes/Code/Personal/MachOSwiftSection && git push
```

Then update the package in RuntimeViewerCore:

```bash
cd /Volumes/Code/Personal/RuntimeViewer/RuntimeViewerCore && swift package update MachOSwiftSection
```

If it's a local path dependency (likely), just ensure the local changes are saved — SPM will pick them up automatically.

- [ ] **Step 2: Full build verification**

```bash
cd /Volumes/Code/Personal/RuntimeViewer && xcodebuild build -scheme RuntimeViewerUsingAppKit -configuration Debug -destination 'generic/platform=macOS' 2>&1 | tail -20
```

Expected: Clean build with no errors.

- [ ] **Step 3: Manual smoke test**

Run the app, navigate to any image node in the sidebar. Verify:
1. Progress bar appears instead of spinner
2. Description label shows current phase (e.g., "Loading Objective-C classes...")
3. Count label shows current/total (e.g., "142/1500")
4. Progress bar advances smoothly through phases
5. Fast-loading cached images still skip the loading view (500ms delay logic intact)

- [ ] **Step 4: Final commit if any fixups needed**

```bash
cd /Volumes/Code/Personal/RuntimeViewer
git add -A
git commit -m "chore: finalize sidebar loading progress bar feature"
```
