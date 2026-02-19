# Interface Export Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add unified ObjC/Swift interface export API to RuntimeViewerCore with progress reporting via AsyncStream.

**Architecture:** All export types live in RuntimeViewerCore under a new `Export/` directory. A unified `RuntimeInterfaceExportEvent` enum reports progress through `AsyncStream`. RuntimeEngine gets new `exportInterface` (single) and `exportInterfaces` (batch) methods that delegate to existing `interface(for:options:)` and `objects(in:)`.

**Tech Stack:** Swift 5 mode, Swift Concurrency (actors, AsyncStream), SemanticString from Semantic framework. No new dependencies.

**Compatibility Note:** RuntimeViewerCore targets macOS 10.15+. Use `AsyncStream { continuation in }` init (not `.makeStream()`), and `TimeInterval` (not `Duration`/`ContinuousClock`).

---

### Task 1: Create RuntimeInterfaceExportEvent and RuntimeInterfaceExportResult

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportEvent.swift`

**Step 1: Create the Export directory and event file**

```swift
import Foundation
import Semantic

public enum RuntimeInterfaceExportEvent: Sendable {
    case phaseStarted(Phase)
    case phaseCompleted(Phase)
    case phaseFailed(Phase, any Error)

    case objectStarted(RuntimeObject, current: Int, total: Int)
    case objectCompleted(RuntimeObject, SemanticString)
    case objectFailed(RuntimeObject, any Error)

    case completed(RuntimeInterfaceExportResult)

    public enum Phase: Sendable {
        case preparing
        case exporting
        case writing
    }
}

public struct RuntimeInterfaceExportResult: Sendable {
    public let succeeded: Int
    public let failed: Int
    public let totalDuration: TimeInterval
    public let objcCount: Int
    public let swiftCount: Int

    public init(succeeded: Int, failed: Int, totalDuration: TimeInterval, objcCount: Int, swiftCount: Int) {
        self.succeeded = succeeded
        self.failed = failed
        self.totalDuration = totalDuration
        self.objcCount = objcCount
        self.swiftCount = swiftCount
    }
}
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 3: Commit**

```
feat: Add RuntimeInterfaceExportEvent and RuntimeInterfaceExportResult
```

---

### Task 2: Create RuntimeInterfaceExportReporter

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportReporter.swift`

**Step 1: Create the reporter**

```swift
import Foundation

public final class RuntimeInterfaceExportReporter: Sendable {
    public let events: AsyncStream<RuntimeInterfaceExportEvent>
    private let continuation: AsyncStream<RuntimeInterfaceExportEvent>.Continuation

    public init() {
        var cont: AsyncStream<RuntimeInterfaceExportEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    func send(_ event: RuntimeInterfaceExportEvent) {
        continuation.yield(event)
    }

    func finish() {
        continuation.finish()
    }
}
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 3: Commit**

```
feat: Add RuntimeInterfaceExportReporter with AsyncStream
```

---

### Task 3: Create RuntimeInterfaceExportConfiguration

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportConfiguration.swift`

**Step 1: Create the configuration**

```swift
import Foundation

public struct RuntimeInterfaceExportConfiguration: Sendable {
    public let scope: Scope
    public let format: Format
    public let generationOptions: RuntimeObjectInterface.GenerationOptions

    public init(scope: Scope, format: Format, generationOptions: RuntimeObjectInterface.GenerationOptions) {
        self.scope = scope
        self.format = format
        self.generationOptions = generationOptions
    }

    public enum Scope: Sendable {
        case singleObject(RuntimeObject)
        case image(String)
    }

    public enum Format: Sendable {
        case singleFile
        case directory
    }
}
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 3: Commit**

```
feat: Add RuntimeInterfaceExportConfiguration
```

---

### Task 4: Create RuntimeInterfaceExportItem and RuntimeObject+Export

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportItem.swift`
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Common/RuntimeObject+Export.swift`

**Step 1: Create the export item**

```swift
import Foundation

public struct RuntimeInterfaceExportItem: Sendable {
    public let object: RuntimeObject
    public let plainText: String
    public let suggestedFileName: String

    public init(object: RuntimeObject, plainText: String, suggestedFileName: String) {
        self.object = object
        self.plainText = plainText
        self.suggestedFileName = suggestedFileName
    }

    public var fileExtension: String {
        switch object.kind {
        case .swift: return "swiftinterface"
        case .objc, .c: return "h"
        }
    }

    public var isSwift: Bool {
        if case .swift = object.kind { return true }
        return false
    }
}
```

**Step 2: Create the RuntimeObject export extension**

```swift
import Foundation

extension RuntimeObject {
    public var exportFileName: String {
        let sanitized = displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        switch kind {
        case .swift:
            return "\(sanitized).swiftinterface"
        case .objc, .c:
            return "\(sanitized).h"
        }
    }
}
```

**Step 3: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 4: Commit**

```
feat: Add RuntimeInterfaceExportItem and RuntimeObject.exportFileName
```

---

### Task 5: Create RuntimeInterfaceExportWriter

**Files:**
- Create: `RuntimeViewerCore/Sources/RuntimeViewerCore/Export/RuntimeInterfaceExportWriter.swift`

**Step 1: Create the writer**

```swift
import Foundation

public enum RuntimeInterfaceExportWriter {
    public static func writeSingleFile(
        items: [RuntimeInterfaceExportItem],
        to directory: URL,
        imageName: String,
        reporter: RuntimeInterfaceExportReporter
    ) throws {
        reporter.send(.phaseStarted(.writing))

        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let combined = objcItems.map(\.plainText).joined(separator: "\n\n")
            let file = directory.appendingPathComponent("\(imageName).h")
            try combined.write(to: file, atomically: true, encoding: .utf8)
        }

        if !swiftItems.isEmpty {
            let combined = swiftItems.map(\.plainText).joined(separator: "\n\n")
            let file = directory.appendingPathComponent("\(imageName).swiftinterface")
            try combined.write(to: file, atomically: true, encoding: .utf8)
        }

        reporter.send(.phaseCompleted(.writing))
    }

    public static func writeDirectory(
        items: [RuntimeInterfaceExportItem],
        to directory: URL,
        reporter: RuntimeInterfaceExportReporter
    ) throws {
        reporter.send(.phaseStarted(.writing))

        let objcItems = items.filter { !$0.isSwift }
        let swiftItems = items.filter { $0.isSwift }

        if !objcItems.isEmpty {
            let objcDir = directory.appendingPathComponent("ObjCHeaders")
            try FileManager.default.createDirectory(at: objcDir, withIntermediateDirectories: true)
            for item in objcItems {
                let file = objcDir.appendingPathComponent(item.suggestedFileName)
                try item.plainText.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        if !swiftItems.isEmpty {
            let swiftDir = directory.appendingPathComponent("SwiftInterfaces")
            try FileManager.default.createDirectory(at: swiftDir, withIntermediateDirectories: true)
            for item in swiftItems {
                let file = swiftDir.appendingPathComponent(item.suggestedFileName)
                try item.plainText.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        reporter.send(.phaseCompleted(.writing))
    }
}
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 3: Commit**

```
feat: Add RuntimeInterfaceExportWriter for single-file and directory export
```

---

### Task 6: Add export methods to RuntimeEngine

**Files:**
- Modify: `RuntimeViewerCore/Sources/RuntimeViewerCore/RuntimeEngine.swift` (add extension at end of file, after line 444)

**Step 1: Add export extension to RuntimeEngine**

Append after the existing `RuntimeConnection` extension (end of file):

```swift
// MARK: - Export

extension RuntimeEngine {
    public enum RuntimeExportError: Error {
        case interfaceGenerationFailed(RuntimeObject)
    }

    public func exportInterface(
        for object: RuntimeObject,
        options: RuntimeObjectInterface.GenerationOptions
    ) async throws -> RuntimeInterfaceExportItem {
        guard let runtimeInterface = try await interface(for: object, options: options) else {
            throw RuntimeExportError.interfaceGenerationFailed(object)
        }
        return RuntimeInterfaceExportItem(
            object: object,
            plainText: runtimeInterface.interfaceString.string,
            suggestedFileName: object.exportFileName
        )
    }

    public func exportInterfaces(
        in imagePath: String,
        options: RuntimeObjectInterface.GenerationOptions,
        reporter: RuntimeInterfaceExportReporter
    ) async throws -> [RuntimeInterfaceExportItem] {
        let startTime = CFAbsoluteTimeGetCurrent()

        reporter.send(.phaseStarted(.preparing))
        let allObjects = try await objects(in: imagePath)
        reporter.send(.phaseCompleted(.preparing))

        reporter.send(.phaseStarted(.exporting))
        var results: [RuntimeInterfaceExportItem] = []
        var succeeded = 0
        var failed = 0
        var objcCount = 0
        var swiftCount = 0
        let total = allObjects.count

        for (index, object) in allObjects.enumerated() {
            reporter.send(.objectStarted(object, current: index + 1, total: total))
            do {
                let item = try await exportInterface(for: object, options: options)
                results.append(item)
                succeeded += 1
                if item.isSwift { swiftCount += 1 } else { objcCount += 1 }
                reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
            } catch {
                failed += 1
                reporter.send(.objectFailed(object, error))
            }
        }
        reporter.send(.phaseCompleted(.exporting))

        let duration = CFAbsoluteTimeGetCurrent() - startTime
        let result = RuntimeInterfaceExportResult(
            succeeded: succeeded,
            failed: failed,
            totalDuration: duration,
            objcCount: objcCount,
            swiftCount: swiftCount
        )
        reporter.send(.completed(result))
        reporter.finish()
        return results
    }
}
```

**Important:** The `exportInterfaces` method has a bug in the design — `runtimeInterface` is not in scope inside the loop. Fix: call `interface(for:options:)` directly instead of going through `exportInterface`, or restructure to capture the SemanticString.

Corrected implementation for the loop body:

```swift
for (index, object) in allObjects.enumerated() {
    reporter.send(.objectStarted(object, current: index + 1, total: total))
    do {
        guard let runtimeInterface = try await interface(for: object, options: options) else {
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
        reporter.send(.objectCompleted(object, runtimeInterface.interfaceString))
    } catch {
        failed += 1
        reporter.send(.objectFailed(object, error))
    }
}
```

**Step 2: Build to verify**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift build 2>&1 | xcsift`

**Step 3: Commit**

```
feat: Add exportInterface and exportInterfaces methods to RuntimeEngine
```

---

### Task 7: Full project build verification

**Step 1: Clean build RuntimeViewerCore**

Run: `cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerCore && swift package clean && swift build 2>&1 | xcsift`

**Step 2: Build the main app**

Run: `xcodebuild build -workspace /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewer.xcworkspace -scheme "RuntimeViewerUsingAppKit" -configuration Debug -destination 'generic/platform=macOS' 2>&1 | xcsift`

**Step 3: Commit if any fixes needed**

---

## Files Summary

| File | Action |
|------|--------|
| `RuntimeViewerCore/.../Export/RuntimeInterfaceExportEvent.swift` | Create |
| `RuntimeViewerCore/.../Export/RuntimeInterfaceExportReporter.swift` | Create |
| `RuntimeViewerCore/.../Export/RuntimeInterfaceExportConfiguration.swift` | Create |
| `RuntimeViewerCore/.../Export/RuntimeInterfaceExportItem.swift` | Create |
| `RuntimeViewerCore/.../Export/RuntimeInterfaceExportWriter.swift` | Create |
| `RuntimeViewerCore/.../Common/RuntimeObject+Export.swift` | Create |
| `RuntimeViewerCore/.../RuntimeEngine.swift` | Modify (append extension) |
