# CodeEditorView Gutter & Minimap Port Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port a trimmed cross-platform Gutter (line numbers + current-line highlight + click-to-select-line) and Minimap (scaled overview + draggable viewport indicator) from [mchakravarty/CodeEditorView](https://github.com/mchakravarty/CodeEditorView) into a reusable `CodePreviewContainerView` in `RuntimeViewerUI`. Embed it into the existing `ContentTextViewController` on macOS (AppKit) and iOS (UIKit).

**Architecture:** New `RuntimeViewerUI/CodePreview/` directory holds a cross-platform container that orchestrates a main `NSUITextView` + `GutterView` + `MinimapView` + `MinimapViewportIndicator`. Main and minimap text views share a single `NSTextContentStorage`. AppKit uses `addFloatingSubview` for the gutter; UIKit uses `CGAffineTransform` updated from `scrollViewDidScroll`. Two new Settings toggles (`Show Line Numbers`, `Show Minimap`) gate visibility. Colors derive from the existing `ThemeProfile` via extension — no protocol changes.

**Tech Stack:** Swift 6.2 / Swift Package Manager / TextKit 2 / AppKit / UIKit / SwiftUI (Settings only) / Rearrange (already a dependency) / UIFoundation (`NSUI*` typealiases) / SnapKit / RxSwift / MetaCodable (`@Codable` / `@MemberInit` / `@Default`) / `swift-dependencies` (`@Dependency(\.appDefaults)`).

**Design spec:** `Documentations/Plans/2026-05-05-codeeditorview-gutter-minimap-port-design.md` is the authoritative design reference. This plan executes that spec.

**Branch:** All work happens on `feature/code-preview-gutter-minimap` (already created and contains the design doc commit `3e66842`).

---

## Prerequisites (one-time, before Task 1)

Confirm before starting:

- Working directory: `/Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer`
- Branch: `feature/code-preview-gutter-minimap` — run `git branch --show-current` to verify.
- Workspace: confirm `../MxIris-Reverse-Engineering.xcworkspace` exists. If yes, builds use `-workspace ../MxIris-Reverse-Engineering.xcworkspace -scheme "RuntimeViewer macOS"`. If absent, use `-project RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit.xcodeproj -scheme "RuntimeViewer macOS"`.
- Tools: `xcodebuild` ≥ Xcode 26.2, `xcsift` (`brew install ldomaradzki/tap/xcsift` if missing).
- For Swift Package tests: from `RuntimeViewerPackages/`, run `swift package update && swift test --filter <TestSuite> 2>&1 | xcsift`.

**Build sanity check (run once):**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewer macOS" \
                 -configuration Debug \
                 -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: build succeeds. If it fails, fix the existing build before continuing.

---

## Task 1: Add `Settings.CodePreview` model

**Files:**
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift`

- [ ] **Step 1: Append `CodePreview` struct in `Settings+Types.swift`**

Add at end of the existing `extension Settings { ... }` block (before its closing `}`):

```swift
    @Codable
    @MemberInit
    public struct CodePreview {
        /// Whether the gutter (line numbers) is shown next to the main text view.
        @Default(true)
        public var showsLineNumbers: Bool

        /// Whether the minimap is shown on the right of the main text view.
        @Default(true)
        public var showsMinimap: Bool

        public static let `default` = Self()
    }
```

- [ ] **Step 2: Add `codePreview` property to `Settings`**

In `RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift`, add a new property after the existing `update` property (before `@IgnoreCoding`):

```swift
    @Default(CodePreview.default)
    public var codePreview: CodePreview = .init() {
        didSet { scheduleAutoSave() }
    }
```

- [ ] **Step 3: Wire `codePreview` into `load()`**

In the same file, in the `private func load() async` body, add after the existing `update = decoded.update` line:

```swift
            codePreview = decoded.codePreview
```

- [ ] **Step 4: Build the Settings package**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift package update
swift build --target RuntimeViewerSettings 2>&1 | xcsift
```

Expected: build succeeds. If `MetaCodable` macro expansion fails, run `swift package clean` first.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings+Types.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerSettings/Settings.swift
git commit -m "feat(settings): add CodePreview toggles for line numbers and minimap"
```

---

## Task 2: Add `NSUITypeAliases.swift`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/NSUITypeAliases.swift`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview
```

- [ ] **Step 2: Write the file**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/NSUITypeAliases.swift`

Content:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

public typealias NSUITextView = NSTextView
public typealias NSUIScrollView = NSScrollView

#elseif canImport(UIKit)
import UIKit

public typealias NSUITextView = UITextView
public typealias NSUIScrollView = UIScrollView

#endif
```

- [ ] **Step 3: Build RuntimeViewerUI**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/NSUITypeAliases.swift
git commit -m "feat(ui): add NSUITextView/NSUIScrollView typealiases for CodePreview"
```

---

## Task 3: Move TextKit 2 extensions to `CodePreview/Internal/`

The existing `RuntimeViewerUI/AppKit/NSTextLayoutManager+.swift` and `NSTextContentStorage+.swift` only use TextKit 2 APIs (cross-platform), but live under `AppKit/` with `#if canImport(AppKit)` guards. Move them into `CodePreview/Internal/` and adjust the guard to `#if canImport(AppKit) || canImport(UIKit)` so the new cross-platform code can use them.

**Files:**
- Move: `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/NSTextLayoutManager+.swift` → `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/NSTextLayoutManager+.swift`
- Move: `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/NSTextContentStorage+.swift` → `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/NSTextContentStorage+.swift`

- [ ] **Step 1: Create internal directory and move files**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
mkdir -p RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal
git mv RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/NSTextLayoutManager+.swift \
       RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/NSTextLayoutManager+.swift
git mv RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/NSTextContentStorage+.swift \
       RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/NSTextContentStorage+.swift
```

- [ ] **Step 2: Update guard in `NSTextLayoutManager+.swift`**

In `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/NSTextLayoutManager+.swift`:

Replace:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
```

With:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
```

And replace the closing `#endif` at end of file with `#endif`.

- [ ] **Step 3: Update guard in `NSTextContentStorage+.swift`**

Same change — replace:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
```

With:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
```

End-of-file `#endif` is already in place.

- [ ] **Step 4: Build for macOS to confirm AppKit path still works**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 5: Build for iOS Simulator to confirm UIKit path compiles**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds. If the scheme name differs or the workspace is absent, fall back to:
```bash
xcodebuild build -project RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit.xcodeproj \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

- [ ] **Step 6: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/Internal/
git commit -m "refactor(ui): move TextKit 2 extensions to cross-platform location"
```

---

## Task 4: Add `RuntimeViewerUITests` test target with `LineMapTests` (TDD)

**Files:**
- Modify: `RuntimeViewerPackages/Package.swift`
- Create: `RuntimeViewerPackages/Tests/RuntimeViewerUITests/LineMapTests.swift`
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/LineMap.swift`

- [ ] **Step 1: Add `RuntimeViewerUITests` test target to `Package.swift`**

In `RuntimeViewerPackages/Package.swift`, add a new test target after the existing `RuntimeViewerApplicationTests` target (in the `targets:` array):

```swift
        .testTarget(
            name: "RuntimeViewerUITests",
            dependencies: [
                "RuntimeViewerUI",
            ]
        ),
```

- [ ] **Step 2: Create test directory and write the failing tests**

Path: `RuntimeViewerPackages/Tests/RuntimeViewerUITests/LineMapTests.swift`

Content:

```swift
import XCTest
@testable import RuntimeViewerUI

final class LineMapTests: XCTestCase {

    // MARK: - Building

    func test_emptyString_hasOneLine() {
        let map = LineMap(string: "")
        XCTAssertEqual(map.lines.count, 1)
        XCTAssertEqual(map.lines[0], NSRange(location: 0, length: 0))
    }

    func test_singleLineNoNewline_hasOneLine() {
        let map = LineMap(string: "hello")
        XCTAssertEqual(map.lines, [NSRange(location: 0, length: 5)])
    }

    func test_singleNewline_yieldsTwoLines() {
        let map = LineMap(string: "a\nb")
        XCTAssertEqual(map.lines, [
            NSRange(location: 0, length: 2),  // "a\n"
            NSRange(location: 2, length: 1),  // "b"
        ])
    }

    func test_trailingNewline_yieldsExtraEmptyLine() {
        let map = LineMap(string: "a\n")
        XCTAssertEqual(map.lines, [
            NSRange(location: 0, length: 2),  // "a\n"
            NSRange(location: 2, length: 0),  // "" (empty trailing line)
        ])
    }

    func test_multipleLines_buildsCorrectRanges() {
        let map = LineMap(string: "abc\ndef\ng")
        XCTAssertEqual(map.lines, [
            NSRange(location: 0, length: 4),  // "abc\n"
            NSRange(location: 4, length: 4),  // "def\n"
            NSRange(location: 8, length: 1),  // "g"
        ])
    }

    func test_crlf_isSplitOnLF_includingCR() {
        // CRLF: '\r' is part of the line, '\n' is the terminator.
        let map = LineMap(string: "a\r\nb")
        XCTAssertEqual(map.lines, [
            NSRange(location: 0, length: 3),  // "a\r\n"
            NSRange(location: 3, length: 1),  // "b"
        ])
    }

    // MARK: - lineNumber(for:)

    func test_lineNumber_atStart_isOne() {
        let map = LineMap(string: "abc\ndef")
        XCTAssertEqual(map.lineNumber(for: 0), 1)
    }

    func test_lineNumber_acrossNewline_advancesByOne() {
        let map = LineMap(string: "abc\ndef")
        XCTAssertEqual(map.lineNumber(for: 2), 1)  // 'c'
        XCTAssertEqual(map.lineNumber(for: 3), 1)  // '\n' belongs to line 1
        XCTAssertEqual(map.lineNumber(for: 4), 2)  // 'd'
    }

    func test_lineNumber_pastEnd_isNil() {
        let map = LineMap(string: "abc")
        XCTAssertNil(map.lineNumber(for: 4))
    }

    func test_lineNumber_atDocumentEnd_returnsLastLine() {
        let map = LineMap(string: "abc\ndef")
        XCTAssertEqual(map.lineNumber(for: 7), 2)  // one past 'f': end of last line
    }

    // MARK: - range(forLine:)

    func test_rangeForLine_oneBased() {
        let map = LineMap(string: "abc\ndef")
        XCTAssertEqual(map.range(forLine: 1), NSRange(location: 0, length: 4))
        XCTAssertEqual(map.range(forLine: 2), NSRange(location: 4, length: 3))
    }

    func test_rangeForLine_outOfRange_isNil() {
        let map = LineMap(string: "abc")
        XCTAssertNil(map.range(forLine: 0))
        XCTAssertNil(map.range(forLine: 2))
    }

    // MARK: - lines(intersecting:)

    func test_linesIntersecting_singleLine() {
        let map = LineMap(string: "abc\ndef\nghi")
        // selection inside line 2
        XCTAssertEqual(map.lines(intersecting: NSRange(location: 5, length: 1)), 2...2)
    }

    func test_linesIntersecting_multiLineSelection() {
        let map = LineMap(string: "abc\ndef\nghi")
        // selection from middle of line 1 to middle of line 3
        XCTAssertEqual(map.lines(intersecting: NSRange(location: 1, length: 8)), 1...3)
    }

    func test_linesIntersecting_emptyRangeAtBoundary() {
        let map = LineMap(string: "abc\ndef")
        // empty range at start of line 2
        XCTAssertEqual(map.lines(intersecting: NSRange(location: 4, length: 0)), 2...2)
    }

    func test_linesIntersecting_outOfBounds_isNil() {
        let map = LineMap(string: "abc")
        XCTAssertNil(map.lines(intersecting: NSRange(location: 100, length: 1)))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail with "no such type"**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift test --filter LineMapTests 2>&1 | xcsift
```

Expected: compile error — `cannot find 'LineMap' in scope`.

- [ ] **Step 4: Write `LineMap.swift`**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/LineMap.swift`

Content:

```swift
#if canImport(AppKit) || canImport(UIKit)
import Foundation

/// Maps between character positions in a string and 1-based line numbers.
///
/// Built once per attributed-string replacement; not designed for incremental edits.
/// Backing storage is a sorted array of `NSRange`s, one per line. The trailing newline
/// of a line (if any) is included in that line's range.
public struct LineMap: Equatable {
    /// One range per line, sorted by `location`, non-overlapping.
    public private(set) var lines: [NSRange]

    public init(string: String) {
        let nsString = string as NSString
        let length = nsString.length

        var lines: [NSRange] = []
        var lineStart = 0
        var index = 0

        while index < length {
            let character = nsString.character(at: index)
            // 0x0A == '\n'. Treat LF as the terminator (CR remains part of the preceding line for CRLF).
            if character == 0x0A {
                lines.append(NSRange(location: lineStart, length: index - lineStart + 1))
                lineStart = index + 1
            }
            index += 1
        }

        // Trailing line: from `lineStart` to end of string. Always present, possibly empty.
        lines.append(NSRange(location: lineStart, length: length - lineStart))

        self.lines = lines
    }

    /// Returns the 1-based line number containing `charIndex`, or `nil` if `charIndex`
    /// lies past the document end.
    public func lineNumber(for charIndex: Int) -> Int? {
        guard !lines.isEmpty else { return nil }

        let last = lines.last!
        let documentEnd = last.location + last.length
        guard charIndex >= 0, charIndex <= documentEnd else { return nil }

        // Binary search.
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let range = lines[mid]
            let rangeEnd = range.location + range.length
            if charIndex < range.location {
                high = mid - 1
            } else if charIndex >= rangeEnd && mid != lines.count - 1 {
                low = mid + 1
            } else {
                return mid + 1  // 1-based
            }
        }
        return nil
    }

    /// Returns the range of characters covered by `lineNumber` (1-based), or `nil` if out of range.
    public func range(forLine lineNumber: Int) -> NSRange? {
        guard lineNumber >= 1, lineNumber <= lines.count else { return nil }
        return lines[lineNumber - 1]
    }

    /// Returns the inclusive range of 1-based line numbers that intersect `range`.
    /// Returns `nil` if `range` is entirely outside the document.
    public func lines(intersecting range: NSRange) -> ClosedRange<Int>? {
        guard !lines.isEmpty else { return nil }

        let last = lines.last!
        let documentEnd = last.location + last.length
        guard range.location <= documentEnd else { return nil }

        let first = lineNumber(for: range.location) ?? 1

        let endIndex = max(range.location, range.location + range.length)
        let last2 = lineNumber(for: min(endIndex, documentEnd)) ?? lines.count
        return first...last2
    }
}

#endif
```

- [ ] **Step 5: Run tests, verify they pass**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift test --filter LineMapTests 2>&1 | xcsift
```

Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Package.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/LineMap.swift \
        RuntimeViewerPackages/Tests/RuntimeViewerUITests/LineMapTests.swift
git commit -m "feat(ui): add LineMap with cross-platform unit tests"
```

---

## Task 5: Add `ThemeColorDerivation.swift` with unit tests (TDD)

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/ThemeColorDerivation.swift`
- Create: `RuntimeViewerPackages/Tests/RuntimeViewerUITests/ThemeColorDerivationTests.swift`

`ThemeColorDerivation` extends `ThemeProfile` (from `RuntimeViewerApplication`) — but `RuntimeViewerUI` doesn't depend on `RuntimeViewerApplication` (the dependency points the other way). Instead, define a small protocol `CodePreviewTheme` in `RuntimeViewerUI` exposing only the bits needed; `ContentTextViewController` adapts `ThemeProfile` → `CodePreviewTheme` at the wire-up site.

- [ ] **Step 1: Write the failing tests**

Tests use a `components(_:)` helper that resolves the receiver to sRGB before reading channels. This is necessary because the production code returns dynamic `NSUIColor(light:dark:)` colors, on which calling `getRed` directly throws on NSColor.

Path: `RuntimeViewerPackages/Tests/RuntimeViewerUITests/ThemeColorDerivationTests.swift`

Content:

```swift
import XCTest
@testable import RuntimeViewerUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
typealias TestColor = NSColor
#elseif canImport(UIKit)
import UIKit
typealias TestColor = UIColor
#endif

private struct StubTheme: CodePreviewTheme {
    let backgroundColor: NSUIColor
    let selectionBackgroundColor: NSUIColor
    let commentColor: NSUIColor
}

final class ThemeColorDerivationTests: XCTestCase {

    private func makeTheme() -> StubTheme {
        StubTheme(
            backgroundColor: TestColor.white,
            selectionBackgroundColor: TestColor.blue,
            commentColor: TestColor.gray
        )
    }

    private func components(_ color: NSUIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let resolved = color.usingColorSpace(.sRGB) ?? color
        return (resolved.redComponent, resolved.greenComponent, resolved.blueComponent, resolved.alphaComponent)
        #else
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
        #endif
    }

    func test_gutterBackgroundColor_isOpaque() {
        let theme = makeTheme()
        XCTAssertGreaterThan(components(theme.gutterBackgroundColor).a, 0.5)
    }

    func test_gutterBackgroundColor_isShiftedFromPlainWhite() {
        // White background → light variant offset by -0.05 → channels < 1.0.
        let theme = makeTheme()
        let derived = components(theme.gutterBackgroundColor)
        // Dynamic color resolves to its light variant under default test trait, so we
        // expect the darker channel here.
        XCTAssertLessThan(derived.r, 1.0)
    }

    func test_gutterLineNumberColor_matchesCommentColor() {
        let theme = makeTheme()
        let line = components(theme.gutterLineNumberColor)
        let comment = components(theme.commentColor)
        XCTAssertEqual(line.r, comment.r, accuracy: 0.001)
        XCTAssertEqual(line.g, comment.g, accuracy: 0.001)
        XCTAssertEqual(line.b, comment.b, accuracy: 0.001)
        XCTAssertEqual(line.a, comment.a, accuracy: 0.001)
    }

    func test_gutterCurrentLineColor_isTranslucentSelectionColor() {
        let theme = makeTheme()
        let alpha = components(theme.gutterCurrentLineColor).a
        XCTAssertGreaterThan(alpha, 0.0)
        XCTAssertLessThan(alpha, 0.5)
    }

    func test_minimapBackgroundColor_matchesGutter() {
        let theme = makeTheme()
        let m = components(theme.minimapBackgroundColor)
        let g = components(theme.gutterBackgroundColor)
        XCTAssertEqual(m.r, g.r, accuracy: 0.001)
        XCTAssertEqual(m.g, g.g, accuracy: 0.001)
        XCTAssertEqual(m.b, g.b, accuracy: 0.001)
        XCTAssertEqual(m.a, g.a, accuracy: 0.001)
    }

    func test_viewportIndicatorColor_isTranslucentSelectionColor() {
        let theme = makeTheme()
        let alpha = components(theme.viewportIndicatorColor).a
        XCTAssertGreaterThan(alpha, 0.10)
        XCTAssertLessThan(alpha, 0.30)
    }

    func test_viewportIndicatorActiveColor_isMoreOpaqueThanIdle() {
        let theme = makeTheme()
        let idle = components(theme.viewportIndicatorColor).a
        let active = components(theme.viewportIndicatorActiveColor).a
        XCTAssertGreaterThan(active, idle)
    }
}
```

- [ ] **Step 2: Run tests to verify failure**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift test --filter ThemeColorDerivationTests 2>&1 | xcsift
```

Expected: compile error — `cannot find 'CodePreviewTheme' in scope`.

- [ ] **Step 3: Write `ThemeColorDerivation.swift`**

Per spec risk R6, the chrome tint is computed by resolving the document background separately in light and dark contexts and offsetting each by a fixed sign — no runtime luminance branching. The result is a fresh `NSUIColor(light:dark:)` that re-evaluates on appearance change.

`RuntimeViewerUI` does not depend on `RuntimeViewerApplication`, so the `NSUIColor(light:dark:)` convenience is reproduced locally in this file (kept `internal` to avoid colliding with the application-side public version).

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/ThemeColorDerivation.swift`

Content:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
import UIFoundation

/// Minimal theme contract consumed by `CodePreviewContainerView`. Adapter wiring at the
/// integration site (`ContentTextViewController`) maps the application's `ThemeProfile`
/// to this protocol.
public protocol CodePreviewTheme {
    var backgroundColor: NSUIColor { get }
    var selectionBackgroundColor: NSUIColor { get }
    /// Color used for code comments — reused as the gutter line-number color.
    var commentColor: NSUIColor { get }
}

extension CodePreviewTheme {
    /// Slightly tinted background used for both gutter and minimap. The light variant
    /// is offset darker by 5%; the dark variant is offset lighter by 5%. The result is
    /// a dynamic color that follows appearance changes.
    public var gutterBackgroundColor: NSUIColor {
        let lightTint = backgroundColor.codePreview_resolvedLight.codePreview_offset(by: -0.05)
        let darkTint = backgroundColor.codePreview_resolvedDark.codePreview_offset(by: 0.05)
        return NSUIColor.codePreview_dynamic(light: lightTint, dark: darkTint)
    }

    public var gutterLineNumberColor: NSUIColor { commentColor }

    public var gutterCurrentLineColor: NSUIColor {
        selectionBackgroundColor.withAlphaComponent(0.15)
    }

    public var minimapBackgroundColor: NSUIColor { gutterBackgroundColor }

    public var viewportIndicatorColor: NSUIColor {
        selectionBackgroundColor.withAlphaComponent(0.18)
    }

    public var viewportIndicatorActiveColor: NSUIColor {
        selectionBackgroundColor.withAlphaComponent(0.30)
    }
}

// MARK: - Light/dark resolution

extension NSUIColor {
    /// The receiver evaluated in a light-appearance context. For static colors, returns
    /// the receiver unchanged. For dynamic `NSUIColor(light:dark:)` colors, returns the
    /// resolved light variant.
    fileprivate var codePreview_resolvedLight: NSUIColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return resolved(in: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing())
        #elseif canImport(UIKit)
        return self.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light))
        #endif
    }

    /// The receiver evaluated in a dark-appearance context.
    fileprivate var codePreview_resolvedDark: NSUIColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return resolved(in: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
        #elseif canImport(UIKit)
        return self.resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
        #endif
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    fileprivate func resolved(in appearance: NSAppearance) -> NSUIColor {
        var result: NSUIColor = self
        appearance.performAsCurrentDrawingAppearance {
            // Resolving via sRGB color space forces dynamic-color evaluation under the
            // current drawing appearance.
            result = self.usingColorSpace(.sRGB) ?? self
        }
        return result
    }
    #endif
}

// MARK: - Offset & dynamic constructor

extension NSUIColor {
    /// Returns this color with each RGB channel shifted by `delta` (clamped to 0...1).
    /// Alpha is preserved.
    fileprivate func codePreview_offset(by delta: CGFloat) -> NSUIColor {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let normalized = self.usingColorSpace(.sRGB) ?? self
        normalized.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #else
        self.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        #endif
        return NSUIColor(
            red: max(0, min(1, red + delta)),
            green: max(0, min(1, green + delta)),
            blue: max(0, min(1, blue + delta)),
            alpha: alpha
        )
    }

    /// Constructs a dynamic color whose appearance follows light/dark mode. Reproduced
    /// locally because `RuntimeViewerUI` does not depend on the application target where
    /// the equivalent public initializer lives.
    static func codePreview_dynamic(light: NSUIColor, dark: NSUIColor) -> NSUIColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            return isDark ? dark : light
        }
        #elseif canImport(UIKit)
        return UIColor { traitCollection in
            traitCollection.userInterfaceStyle == .dark ? dark : light
        }
        #endif
    }
}

#endif
```

- [ ] **Step 4: Run tests, verify pass**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift test --filter ThemeColorDerivationTests 2>&1 | xcsift
```

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/ThemeColorDerivation.swift \
        RuntimeViewerPackages/Tests/RuntimeViewerUITests/ThemeColorDerivationTests.swift
git commit -m "feat(ui): add CodePreviewTheme protocol and color derivations"
```

---

## Task 6: Move and cross-platform-ify `MinimapView`

**Files:**
- Move: `RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/MinimapView.swift` → `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapView.swift`
- Modify the moved file to support both AppKit and UIKit.

- [ ] **Step 1: Move the file**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git mv RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/MinimapView.swift \
       RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapView.swift
```

- [ ] **Step 2: Replace top-level guard with cross-platform guard**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapView.swift`

Replace the opening:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
```

With:
```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
import UIFoundation
```

- [ ] **Step 3: Adapt `MinimapView` class to use NSUITextView**

Replace the `class MinimapView: NSTextView { ... }` block (currently lines 10–37 in the moved file) with:

```swift
/// Customised text view for the minimap.
///
final class MinimapView: NSUITextView {
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    // Highlight the current line.
    override func drawBackground(in rect: NSRect) {
        let rectWithinBounds = rect.intersection(bounds)
        super.drawBackground(in: rectWithinBounds)

        guard let textLayoutManager = textLayoutManager,
              let textContentStorage = textContentStorage
        else { return }

        let viewportRange = textLayoutManager.textViewportLayoutController.viewportRange

        if let location = insertionPoint,
           let textLocation = textContentStorage.textLocation(for: location) {
            if viewportRange == nil
                || viewportRange!.contains(textLocation)
                || viewportRange!.endLocation.compare(textLocation) == .orderedSame {
                drawBackgroundHighlight(
                    within: rectWithinBounds,
                    forLineContaining: textLocation,
                    withColour: .textBackgroundColor
                )
            }
        }
    }
    #endif

    // UIKit has no equivalent override of drawBackground; current-line highlight on iOS
    // is rendered via the gutter's highlight (see GutterView). Minimap on iOS just
    // shows the scaled glyph boxes without the per-line background fill.
}
```

- [ ] **Step 4: Adapt `NSTextView` extension at end of file to a `NSUITextView` extension**

Replace the `extension NSTextView { ... }` block with:

```swift
extension NSUITextView {
    typealias Color = NSUIColor
    typealias Font = NSUIFont

    var optTextLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var optTextContainer: NSTextContainer? { textContainer }
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    var optTextContentStorage: NSTextContentStorage? { textContentStorage }
    #else
    var optTextContentStorage: NSTextContentStorage? { textLayoutManager?.textContentManager as? NSTextContentStorage }
    #endif

    var textBackgroundColor: NSUIColor? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return backgroundColor
        #else
        return self.backgroundColor
        #endif
    }

    var textFont: NSUIFont? { font }

    var textContainerOrigin: CGPoint {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return CGPoint(x: textContainerInset.width, y: textContainerInset.height)
        #else
        return CGPoint(x: textContainerInset.left, y: textContainerInset.top)
        #endif
    }

    var text: String! {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        get { string }
        set { string = newValue }
        #else
        get { self.text ?? "" }
        set { self.text = newValue }
        #endif
    }

    var insertionPoint: Int? {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let selection = selectedRanges.first as? NSRange, selection.length == 0 { return selection.location }
        else { return nil }
        #else
        let selection = self.selectedRange
        return selection.length == 0 ? selection.location : nil
        #endif
    }

    var documentVisibleRect: CGRect {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return enclosingScrollView?.documentVisibleRect ?? bounds
        #else
        return bounds
        #endif
    }

    var contentSize: CGSize { bounds.size }

    func drawBackgroundHighlight(within rect: CGRect,
                                 forLineContaining textLocation: NSTextLocation,
                                 withColour colour: NSUIColor) {
        guard let textLayoutManager = optTextLayoutManager else { return }

        colour.setFill()
        if let fragmentFrame = textLayoutManager.textLayoutFragment(for: textLocation)?.layoutFragmentFrameWithoutExtraLineFragment,
           let highlightRect = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height) {
            let clippedRect = highlightRect.intersection(rect)
            if !clippedRect.isNull { NSUIBezierPath(rect: clippedRect).fill() }

        } else
        if let previousLocation = optTextContentStorage?.location(textLocation, offsetBy: -1),
           let fragmentFrame = textLayoutManager.textLayoutFragment(for: previousLocation)?.layoutFragmentFrameExtraLineFragment,
           let highlightRect = lineBackgroundRect(y: fragmentFrame.minY, height: fragmentFrame.height) {
            let clippedRect = highlightRect.intersection(rect)
            if !clippedRect.isNull { NSUIBezierPath(rect: clippedRect).fill() }
        }
    }

    func lineBackgroundRect(y: CGFloat, height: CGFloat) -> CGRect? {
        return CGRect(x: 0, y: y, width: bounds.size.width, height: height)
    }
}
```

The four classes below the `MinimapView` class (`MinimapLineFragment`, `MinimapLayoutFragment`, `MinimapTextLayoutManagerDelegate`, plus the `minimapRatio` constant and the `NSAttributedString.Key.hideInvisibles` extension) use only TextKit 2 cross-platform APIs and need no changes.

- [ ] **Step 5: Verify file ends with the cross-platform `#endif`**

Open the file and confirm the very last line is `#endif` (closing the `#if canImport(AppKit) || canImport(UIKit)` from Step 2). The original file's `#endif` is now this terminator.

- [ ] **Step 6: Build for macOS**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 7: Build for iOS Simulator**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 8: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapView.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerUI/AppKit/MinimapView.swift
git commit -m "refactor(ui): make MinimapView cross-platform under CodePreview/"
```

---

## Task 7: Add `GutterView`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/GutterView.swift`

- [ ] **Step 1: Write the file**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/GutterView.swift`

Content:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
import UIFoundation

/// A view that renders line numbers + a current-line highlight band, for placement to
/// the left of a `NSUITextView`.
///
/// On AppKit, this view is added to the host scroll view via
/// `addFloatingSubview(_, for: .vertical)`, which keeps it visually pinned to the left
/// edge while scrolling. On UIKit, the view is a sibling of the scroll view inside the
/// container, and is kept visually pinned by setting `verticalOffset` from the scroll
/// view's `contentOffset.y`.
public final class GutterView: NSUIView {

    // MARK: - Inputs

    public weak var textView: NSUITextView?
    public weak var scrollView: NSUIScrollView?

    public var lineMap: LineMap = LineMap(string: "") {
        didSet { setNeedsDisplay() }
    }

    public var theme: CodePreviewTheme? {
        didSet { setNeedsDisplay() }
    }

    /// Inclusive range of 1-based line numbers to draw with the current-line highlight band.
    /// Nil means no highlight.
    public var highlightedLines: ClosedRange<Int>? {
        didSet { setNeedsDisplay() }
    }

    /// UIKit only: the scroll view's content-offset y, used to translate gutter rendering
    /// to align with the scrolled text. Ignored on AppKit (where `addFloatingSubview` keeps
    /// the gutter visually pinned).
    #if canImport(UIKit) && !canImport(AppKit)
    public var verticalOffset: CGFloat = 0 {
        didSet { setNeedsDisplay() }
    }
    #endif

    // MARK: - Lifecycle

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func commonInit() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        wantsLayer = true
        #endif
    }

    // MARK: - Sizing

    /// Preferred width: enough for 7-digit line numbers + horizontal padding.
    public var preferredWidth: CGFloat {
        let font = lineNumberFont
        let advancement = font.maximumHorizontalAdvancement
        return ceil(advancement * 7) + 12   // 6pt padding on each side
    }

    private var lineNumberFont: NSUIFont {
        if let textFont = textView?.textFont {
            let size = textFont.pointSize
            return NSUIFont.monospacedDigitSystemFont(ofSize: size, weight: .regular)
        }
        return NSUIFont.monospacedDigitSystemFont(ofSize: NSUIFont.systemFontSize, weight: .regular)
    }

    // MARK: - Drawing

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public override var isFlipped: Bool { true }

    public override func draw(_ dirtyRect: NSRect) {
        drawGutter(in: dirtyRect)
    }
    #else
    public override func draw(_ rect: CGRect) {
        drawGutter(in: rect)
    }

    public override var isOpaque: Bool { true }
    #endif

    private func drawGutter(in dirtyRect: CGRect) {
        guard let textView = textView else { return }
        let theme = self.theme

        // Background.
        (theme?.gutterBackgroundColor ?? defaultBackgroundColor).setFill()
        NSUIBezierPath(rect: dirtyRect).fill()

        guard let textLayoutManager = textView.optTextLayoutManager,
              let textContentStorage = textView.optTextContentStorage,
              let textContainer = textView.optTextContainer
        else { return }

        let lineNumberColor = theme?.gutterLineNumberColor ?? defaultLineNumberColor
        let highlightColor = theme?.gutterCurrentLineColor ?? defaultHighlightColor
        let font = lineNumberFont
        let textAttrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: lineNumberColor,
        ]

        // Compute vertical translation that aligns gutter rows with the text view's rows.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // AppKit: gutter is a floating subview; the text view's frame in the scroll view
        // moves as the user scrolls, so translating by -textView.frame.minY brings the
        // text view's coordinate space into the gutter's coordinate space.
        let textViewFrameInGutter = convert(textView.bounds, from: textView)
        let translateY = textViewFrameInGutter.minY - textView.textContainerOrigin.y
        #else
        let translateY = -verticalOffset
        #endif

        // Walk text layout fragments, draw a number for each visible line.
        let documentRange = textLayoutManager.documentRange
        textLayoutManager.enumerateTextLayoutFragments(from: documentRange.location, options: []) { fragment in

            let fragmentFrame = fragment.layoutFragmentFrameWithoutExtraLineFragment
            let lineY = fragmentFrame.minY + translateY
            let lineHeight = fragmentFrame.height

            // Out of dirty rect on top — keep walking; on bottom — stop.
            if lineY + lineHeight < dirtyRect.minY { return true }
            if lineY > dirtyRect.maxY { return false }

            let firstChar = textContentStorage.location(for: fragment.rangeInElement.location)
            guard let lineNumber = lineMap.lineNumber(for: firstChar) else { return true }

            // Highlight band, if applicable.
            if let highlightedLines = highlightedLines, highlightedLines.contains(lineNumber) {
                highlightColor.setFill()
                NSUIBezierPath(rect: CGRect(x: 0, y: lineY, width: bounds.width, height: lineHeight)).fill()
            }

            // Line number, right-aligned with 6pt right padding.
            let numberString = NSAttributedString(string: "\(lineNumber)", attributes: textAttrs)
            let stringSize = numberString.size()
            let stringX = bounds.width - stringSize.width - 6
            let stringY = lineY + (lineHeight - stringSize.height) / 2
            numberString.draw(at: CGPoint(x: stringX, y: stringY))
            return true
        }
    }

    private var defaultBackgroundColor: NSUIColor {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return .windowBackgroundColor
        #else
        return .systemGray6
        #endif
    }

    private var defaultLineNumberColor: NSUIColor { .secondaryLabelColor }
    private var defaultHighlightColor: NSUIColor { defaultLineNumberColor.withAlphaComponent(0.10) }

    // MARK: - Interaction

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public override func mouseDown(with event: NSEvent) {
        let pointInGutter = convert(event.locationInWindow, from: nil)
        selectLine(at: pointInGutter.y)
    }
    #else
    public override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        addGestureRecognizer(tap)
    }

    @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
        let location = recognizer.location(in: self)
        selectLine(at: location.y)
    }
    #endif

    private func selectLine(at gutterY: CGFloat) {
        guard let textView = textView,
              let textLayoutManager = textView.optTextLayoutManager,
              let textContentStorage = textView.optTextContentStorage
        else { return }

        // Translate gutter y → text view y.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let textViewFrameInGutter = convert(textView.bounds, from: textView)
        let translateY = textViewFrameInGutter.minY - textView.textContainerOrigin.y
        #else
        let translateY = -verticalOffset
        #endif
        let textY = gutterY - translateY

        // Find the layout fragment at that y.
        var hitFragment: NSTextLayoutFragment?
        textLayoutManager.enumerateTextLayoutFragments(from: textLayoutManager.documentRange.location, options: []) { fragment in
            let frame = fragment.layoutFragmentFrameWithoutExtraLineFragment
            if frame.minY <= textY && textY < frame.maxY {
                hitFragment = fragment
                return false
            }
            return true
        }
        guard let fragment = hitFragment else { return }

        let firstChar = textContentStorage.location(for: fragment.rangeInElement.location)
        guard let lineNumber = lineMap.lineNumber(for: firstChar),
              let lineRange = lineMap.range(forLine: lineNumber)
        else { return }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        textView.setSelectedRange(lineRange)
        #else
        textView.selectedRange = lineRange
        #endif
    }
}

#endif
```

- [ ] **Step 2: Build**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 3: Build for iOS Simulator**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/GutterView.swift
git commit -m "feat(ui): add cross-platform GutterView"
```

---

## Task 8: Add `MinimapViewportIndicator`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapViewportIndicator.swift`

- [ ] **Step 1: Write the file**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapViewportIndicator.swift`

Content:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
import UIFoundation

/// A translucent rectangle overlaid on the minimap that represents the visible region of
/// the main text view. Drag to scroll the main view proportionally; tap (outside this
/// indicator, on the minimap) is handled by the parent container.
public final class MinimapViewportIndicator: NSUIView {

    public var idleColor: NSUIColor = .clear {
        didSet { updateFill() }
    }

    public var activeColor: NSUIColor = .clear {
        didSet { updateFill() }
    }

    /// Called when the user drags the indicator. Argument is the delta-y in indicator
    /// coordinates (positive = down).
    public var onDrag: ((CGFloat) -> Void)?

    /// Called when the user finishes a drag (mouseUp / pan ended).
    public var onDragEnded: (() -> Void)?

    // MARK: - State

    private var isDragging: Bool = false {
        didSet { updateFill() }
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private var isHovered: Bool = false {
        didSet { updateFill() }
    }
    private var trackingArea: NSTrackingArea?
    #endif

    // MARK: - Lifecycle

    public override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func commonInit() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        wantsLayer = true
        layer?.cornerRadius = 2
        #else
        layer.cornerRadius = 2
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)
        #endif
        updateFill()
    }

    // MARK: - Fill

    private func updateFill() {
        let color = (isDragging
            #if canImport(AppKit) && !targetEnvironment(macCatalyst)
            || isHovered
            #endif
        ) ? activeColor : idleColor

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        layer?.backgroundColor = color.cgColor
        #else
        layer.backgroundColor = color.cgColor
        #endif
    }

    // MARK: - AppKit interaction

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    public override func mouseEntered(with event: NSEvent) {
        isHovered = true
        NSCursor.openHand.push()
    }

    public override func mouseExited(with event: NSEvent) {
        isHovered = false
        NSCursor.pop()
    }

    private var dragStartLocationInWindow: NSPoint = .zero

    public override func mouseDown(with event: NSEvent) {
        isDragging = true
        dragStartLocationInWindow = event.locationInWindow
    }

    public override func mouseDragged(with event: NSEvent) {
        let deltaY = event.locationInWindow.y - dragStartLocationInWindow.y
        // AppKit: in-window y increases upward; gutter / minimap views are flipped, but
        // event.locationInWindow is in the unflipped window coordinate system.
        // We pass -deltaY so positive delta means "moved down on screen".
        onDrag?(-deltaY)
        dragStartLocationInWindow = event.locationInWindow
    }

    public override func mouseUp(with event: NSEvent) {
        isDragging = false
        onDragEnded?()
    }
    #endif

    // MARK: - UIKit interaction

    #if canImport(UIKit) && !canImport(AppKit) || targetEnvironment(macCatalyst)
    private var dragLastTranslationY: CGFloat = 0

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            isDragging = true
            dragLastTranslationY = 0
        case .changed:
            let translation = recognizer.translation(in: superview)
            let delta = translation.y - dragLastTranslationY
            onDrag?(delta)
            dragLastTranslationY = translation.y
        case .ended, .cancelled, .failed:
            isDragging = false
            onDragEnded?()
        default:
            break
        }
    }
    #endif
}

#endif
```

- [ ] **Step 2: Build**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 3: Build for iOS Simulator**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/MinimapViewportIndicator.swift
git commit -m "feat(ui): add MinimapViewportIndicator with drag-to-scroll"
```

---

## Task 9: Add `CodePreviewContainerView` orchestrator

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/CodePreviewContainerView.swift`

This is the largest single file in the plan. It orchestrates everything: shared content storage, layout (`tile()`), scroll synchronization, theme application, click-on-minimap navigation, gutter selection-tracking.

- [ ] **Step 1: Write the file**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/CodePreviewContainerView.swift`

Content:

```swift
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit) || canImport(UIKit)
import UIFoundation

/// A reusable container that pairs a main `NSUITextView` with a `GutterView` and a
/// `MinimapView` plus its viewport indicator. Embed this where you would normally place
/// a single `NSScrollView`-wrapped text view.
public final class CodePreviewContainerView: NSUIView {

    // MARK: - Public API

    public let textView: NSUITextView

    public var attributedString: NSAttributedString? {
        didSet { applyAttributedString() }
    }

    public var theme: CodePreviewTheme? {
        didSet { applyTheme() }
    }

    public var showsLineNumbers: Bool = true {
        didSet {
            guard oldValue != showsLineNumbers else { return }
            tile()
        }
    }

    public var showsMinimap: Bool = true {
        didSet {
            guard oldValue != showsMinimap else { return }
            tile()
        }
    }

    /// Forwarded from the main text view's link click.
    public var onLinkClicked: ((Any, Int) -> Void)?

    public var minimapWidth: CGFloat = 100 {
        didSet { tile() }
    }

    // MARK: - Internals

    private let mainScrollView: NSUIScrollView
    private let gutterView: GutterView
    private let minimapScrollView: NSUIScrollView
    private let minimapView: MinimapView
    private let viewportIndicator: MinimapViewportIndicator
    private let minimapLayoutManagerDelegate = MinimapTextLayoutManagerDelegate()

    private var lineMap: LineMap = LineMap(string: "") {
        didSet { gutterView.lineMap = lineMap }
    }

    /// Set during indicator drag; suppresses the minimap-follow handler in
    /// `mainBoundsDidChange` so we don't get a feedback loop.
    private var isDriverScroll: Bool = false

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    private var boundsObservation: Any?
    #else
    private var contentOffsetObservation: NSKeyValueObservation?
    #endif

    // MARK: - Init

    /// - Parameter textViewType: lets callers pass a specific `NSTextView`/`UITextView`
    ///   subclass (e.g. `ContentTextView`) so the container's `textView` is that type.
    public init(textViewType: NSUITextView.Type) {
        self.textView = Self.makeTextView(of: textViewType)
        self.mainScrollView = NSUIScrollView()
        self.gutterView = GutterView(frame: .zero)
        self.minimapView = Self.makeMinimapTextView()
        self.minimapScrollView = NSUIScrollView()
        self.viewportIndicator = MinimapViewportIndicator(frame: .zero)
        super.init(frame: .zero)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeTextView(of type: NSUITextView.Type) -> NSUITextView {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return type.init(usingTextLayoutManager: true)
        #else
        return type.init(usingTextLayoutManager: true)
        #endif
    }

    private static func makeMinimapTextView() -> MinimapView {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let view = MinimapView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        view.drawsBackground = true
        return view
        #else
        let view = MinimapView(usingTextLayoutManager: true)
        view.isEditable = false
        view.isSelectable = false
        return view
        #endif
    }

    private func commonInit() {
        // Wire shared content storage (so main and minimap render the same text without duplication).
        if let mainContentStorage = textView.optTextContentStorage,
           let minimapLayoutManager = minimapView.optTextLayoutManager {
            // Adding the minimap's layout manager as a secondary on the shared content storage
            // makes both layout managers share the same underlying text storage.
            mainContentStorage.addTextLayoutManager(minimapLayoutManager)
            mainContentStorage.primaryTextLayoutManager = textView.optTextLayoutManager
            minimapLayoutManager.delegate = minimapLayoutManagerDelegate
        }

        // Main scroll view setup.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        mainScrollView.hasVerticalScroller = true
        mainScrollView.hasHorizontalScroller = false
        mainScrollView.documentView = textView
        mainScrollView.contentView.postsBoundsChangedNotifications = true

        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        #else
        textView.isScrollEnabled = false
        // We embed textView in our own scroll view (mainScrollView) and disable the
        // textView's own scroll so we have a unified scroll source.
        mainScrollView.addSubview(textView)
        #endif

        // Minimap scroll view setup.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        minimapScrollView.hasVerticalScroller = false
        minimapScrollView.hasHorizontalScroller = false
        minimapScrollView.drawsBackground = true
        minimapScrollView.documentView = minimapView
        minimapScrollView.scrollerStyle = .overlay
        minimapView.isVerticallyResizable = true
        minimapView.autoresizingMask = [.width]
        minimapView.textContainer?.widthTracksTextView = true
        minimapView.textContainer?.heightTracksTextView = false
        #else
        minimapScrollView.isScrollEnabled = false
        minimapScrollView.showsVerticalScrollIndicator = false
        minimapScrollView.showsHorizontalScrollIndicator = false
        minimapScrollView.addSubview(minimapView)
        #endif

        gutterView.textView = textView
        gutterView.scrollView = mainScrollView

        // Hierarchy.
        addSubview(mainScrollView)
        addSubview(minimapScrollView)
        minimapScrollView.addSubview(viewportIndicator)

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        // Gutter floats inside the main scroll view (TextKit scroll-pinning).
        mainScrollView.addFloatingSubview(gutterView, for: .vertical)
        #else
        // UIKit: gutter is a sibling of the scroll view; we'll translate manually.
        addSubview(gutterView)
        #endif

        // Subscriptions.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        boundsObservation = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: mainScrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.mainBoundsDidChange()
        }
        #else
        contentOffsetObservation = mainScrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.mainBoundsDidChange()
        }
        #endif

        // Selection-change → highlighted line update.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textViewDidChangeSelection(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        #else
        // UIKit textViewDidChangeSelection is a delegate hook — set up a forwarding
        // delegate later in the host (ContentTextViewController).
        // As a fallback, observe selectedTextRange via KVO.
        // (UITextView.selectedTextRange is KVO-compliant in practice on modern iOS.)
        #endif

        // Viewport indicator drag wiring.
        viewportIndicator.onDrag = { [weak self] deltaScreenY in
            self?.handleIndicatorDrag(deltaScreenY: deltaScreenY)
        }
        viewportIndicator.onDragEnded = { [weak self] in
            self?.isDriverScroll = false
        }

        // Minimap click (non-indicator area) → jump.
        installMinimapTapGesture()

        tile()
    }

    deinit {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        if let observation = boundsObservation {
            NotificationCenter.default.removeObserver(observation)
        }
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    // MARK: - Layout

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    public override func layout() {
        super.layout()
        tile()
    }
    #else
    public override func layoutSubviews() {
        super.layoutSubviews()
        tile()
    }
    #endif

    private func tile() {
        let bounds = self.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }

        gutterView.isHidden = !showsLineNumbers
        minimapScrollView.isHidden = !showsMinimap

        let gutterWidth: CGFloat = showsLineNumbers ? gutterView.preferredWidth : 0
        let minimapTotalWidth: CGFloat = showsMinimap ? minimapWidth : 0

        let mainFrame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width - minimapTotalWidth,
            height: bounds.height
        )
        mainScrollView.frame = mainFrame

        // Inset main text content so it doesn't underlap the floating gutter.
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        textView.textContainerInset = NSSize(width: 5 + gutterWidth, height: 5)
        // Gutter floating subview: x at 0, height covers visible portion of clip view.
        let clipBounds = mainScrollView.contentView.bounds
        gutterView.frame = CGRect(x: 0, y: clipBounds.minY, width: gutterWidth, height: clipBounds.height)
        #else
        textView.textContainerInset = UIEdgeInsets(top: 5, left: 5 + gutterWidth, bottom: 5, right: 5)
        textView.frame = mainFrame
        gutterView.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: mainFrame.height)
        #endif

        if showsMinimap {
            let minimapFrame = CGRect(
                x: bounds.width - minimapTotalWidth,
                y: 0,
                width: minimapTotalWidth,
                height: bounds.height
            )
            minimapScrollView.frame = minimapFrame
            #if canImport(UIKit) && !canImport(AppKit) || targetEnvironment(macCatalyst)
            minimapView.frame = CGRect(x: 0, y: 0, width: minimapTotalWidth, height: minimapView.contentSize.height)
            #endif
        }

        Task { @MainActor [weak self] in
            self?.adjustScrollPositionOfMinimap()
        }
    }

    // MARK: - Attributed string + line map

    private func applyAttributedString() {
        guard let mainStorage = textView.optTextContentStorage?.textStorage else { return }
        if let attributed = attributedString {
            mainStorage.setAttributedString(attributed)
            lineMap = LineMap(string: attributed.string)
        } else {
            mainStorage.setAttributedString(NSAttributedString(string: ""))
            lineMap = LineMap(string: "")
        }
        Task { @MainActor [weak self] in
            self?.tile()
            self?.adjustScrollPositionOfMinimap()
        }
    }

    // MARK: - Theme

    private func applyTheme() {
        guard let theme = theme else { return }

        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        textView.backgroundColor = theme.backgroundColor
        mainScrollView.backgroundColor = theme.backgroundColor
        minimapView.backgroundColor = theme.minimapBackgroundColor
        minimapScrollView.backgroundColor = theme.minimapBackgroundColor
        #else
        textView.backgroundColor = theme.backgroundColor
        mainScrollView.backgroundColor = theme.backgroundColor
        minimapView.backgroundColor = theme.minimapBackgroundColor
        minimapScrollView.backgroundColor = theme.minimapBackgroundColor
        #endif

        gutterView.theme = theme

        viewportIndicator.idleColor = theme.viewportIndicatorColor
        viewportIndicator.activeColor = theme.viewportIndicatorActiveColor

        gutterView.setNeedsDisplay()
    }

    // MARK: - Selection → gutter highlight

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    @objc private func textViewDidChangeSelection(_ notification: Notification) {
        let selection = (textView.selectedRanges.first as? NSRange) ?? NSRange(location: 0, length: 0)
        gutterView.highlightedLines = lineMap.lines(intersecting: selection)
    }
    #endif

    /// Public hook for UIKit hosts to forward `textViewDidChangeSelection(_:)` from
    /// their delegate.
    public func updateGutterHighlight() {
        let selectedRange: NSRange
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        selectedRange = (textView.selectedRanges.first as? NSRange) ?? NSRange(location: 0, length: 0)
        #else
        selectedRange = textView.selectedRange
        #endif
        gutterView.highlightedLines = lineMap.lines(intersecting: selectedRange)
    }

    // MARK: - Scroll sync

    private func mainBoundsDidChange() {
        guard !isDriverScroll else { return }
        adjustScrollPositionOfMinimap()
    }

    private func adjustScrollPositionOfMinimap() {
        let codeHeight = textViewContentHeight()
        let mainVisibleHeight = mainVisibleHeight()
        let minimapDocumentHeight = minimapContentHeight()
        let minimapVisibleHeight = minimapScrollView.bounds.height

        guard codeHeight > 0, minimapDocumentHeight > 0 else { return }

        let mainOffsetY = mainContentOffsetY()
        let scrollDenominator = max(1, minimapDocumentHeight - minimapVisibleHeight)
        let scrollNumerator = max(0, codeHeight - mainVisibleHeight)

        let scrollFactor: CGFloat = scrollNumerator > 0 ? scrollNumerator / scrollDenominator : 1
        let minimapOffsetY = max(0, min(minimapDocumentHeight - minimapVisibleHeight, mainOffsetY / scrollFactor))

        setMinimapContentOffsetY(minimapOffsetY)

        // Indicator geometry, in minimap-local coordinates.
        let indicatorY = (mainOffsetY / codeHeight) * minimapDocumentHeight - minimapOffsetY
        let indicatorH = (mainVisibleHeight / codeHeight) * minimapDocumentHeight
        viewportIndicator.frame = CGRect(
            x: 0,
            y: indicatorY,
            width: minimapScrollView.bounds.width,
            height: max(20, indicatorH)
        )
    }

    private func handleIndicatorDrag(deltaScreenY: CGFloat) {
        isDriverScroll = true

        let codeHeight = textViewContentHeight()
        let minimapDocumentHeight = minimapContentHeight()
        guard codeHeight > 0, minimapDocumentHeight > 0 else { return }

        // Indicator delta-y maps back to main-document delta-y by inverting the
        // proportional mapping in adjustScrollPositionOfMinimap.
        let mappingFactor = codeHeight / minimapDocumentHeight
        let mainDelta = deltaScreenY * mappingFactor

        let newOffsetY = max(0, min(codeHeight - mainVisibleHeight(), mainContentOffsetY() + mainDelta))
        setMainContentOffsetY(newOffsetY)
        adjustScrollPositionOfMinimap()
    }

    private func installMinimapTapGesture() {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleMinimapClick(_:)))
        minimapScrollView.addGestureRecognizer(click)
        #else
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleMinimapClick(_:)))
        minimapScrollView.addGestureRecognizer(tap)
        #endif
    }

    @objc private func handleMinimapClick(_ recognizer: NSUIGestureRecognizer) {
        let tapPoint = recognizer.location(in: minimapScrollView)
        // Don't hijack a tap if the indicator was actually under the press; it has its own gesture.
        if viewportIndicator.frame.contains(tapPoint) { return }

        let codeHeight = textViewContentHeight()
        let minimapDocumentHeight = minimapContentHeight()
        guard codeHeight > 0, minimapDocumentHeight > 0 else { return }

        let docY = (tapPoint.y + minimapContentOffsetY()) * (codeHeight / minimapDocumentHeight)
        let centeredOffsetY = max(0, min(codeHeight - mainVisibleHeight(), docY - mainVisibleHeight() / 2))
        setMainContentOffsetY(centeredOffsetY)
        adjustScrollPositionOfMinimap()
    }

    // MARK: - Geometry helpers (platform-specific)

    private func textViewContentHeight() -> CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return textView.frame.height
        #else
        return textView.frame.height
        #endif
    }

    private func mainVisibleHeight() -> CGFloat {
        return mainScrollView.bounds.height
    }

    private func minimapContentHeight() -> CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return minimapView.frame.height
        #else
        return minimapView.bounds.height
        #endif
    }

    private func mainContentOffsetY() -> CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return mainScrollView.contentView.bounds.origin.y
        #else
        return mainScrollView.contentOffset.y
        #endif
    }

    private func setMainContentOffsetY(_ y: CGFloat) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        mainScrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        mainScrollView.reflectScrolledClipView(mainScrollView.contentView)
        #else
        mainScrollView.contentOffset = CGPoint(x: 0, y: y)
        #endif
    }

    private func minimapContentOffsetY() -> CGFloat {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        return minimapScrollView.contentView.bounds.origin.y
        #else
        return minimapScrollView.contentOffset.y
        #endif
    }

    private func setMinimapContentOffsetY(_ y: CGFloat) {
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        minimapScrollView.contentView.scroll(to: NSPoint(x: 0, y: y))
        minimapScrollView.reflectScrolledClipView(minimapScrollView.contentView)
        #else
        minimapScrollView.contentOffset = CGPoint(x: 0, y: y)
        #endif
    }
}

// MARK: - Cross-platform gesture-recognizer typealias

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
public typealias NSUIGestureRecognizer = NSGestureRecognizer
#elseif canImport(UIKit)
public typealias NSUIGestureRecognizer = UIGestureRecognizer
#endif

#endif
```

- [ ] **Step 2: Build for macOS**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerUI 2>&1 | xcsift
```

Expected: build succeeds. If errors mention `optTextLayoutManager`, `optTextContainer`, or `optTextContentStorage`, those come from Task 6 — verify the `NSUITextView` extension was correctly written.

- [ ] **Step 3: Build for iOS Simulator**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add RuntimeViewerPackages/Sources/RuntimeViewerUI/CodePreview/CodePreviewContainerView.swift
git commit -m "feat(ui): add CodePreviewContainerView orchestrator"
```

---

## Task 10: Add Settings UI for `CodePreview`

**Files:**
- Create: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/CodePreviewSettingsView.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`
- Modify: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsIcon.swift`

- [ ] **Step 1: Read existing `SettingsRootView.swift` and `SettingsIcon.swift`**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
cat RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift
cat RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsIcon.swift
```

This step is informational — note the pattern used for existing tabs (e.g., `GeneralSettingsView`, `MCPSettingsView`). The two modifications below mirror that pattern.

- [ ] **Step 2: Create `CodePreviewSettingsView.swift`**

Path: `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/CodePreviewSettingsView.swift`

Content:

```swift
#if os(macOS)

import SwiftUI
import RuntimeViewerSettings

struct CodePreviewSettingsView: View {
    @AppSettings(\.codePreview)
    var settings

    var body: some View {
        SettingsForm {
            Section {
                Toggle("Show Line Numbers", isOn: $settings.showsLineNumbers)
                Toggle("Show Minimap", isOn: $settings.showsMinimap)
            }
        }
    }
}

#endif
```

- [ ] **Step 3: Register the new tab in `SettingsRootView.swift`**

Open `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift`. Find the `TabView` (or equivalent navigation) where existing settings tabs are registered. Add a new tab matching the pattern, e.g.:

```swift
            CodePreviewSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.alignleft")
                }
                .tag(SettingsTab.codePreview)
```

If there is a `SettingsTab` enum in the file, add a `case codePreview` to it. Match the exact placement style used by adjacent tabs (the `MCPSettingsView` registration is the most similar in spirit).

- [ ] **Step 4: Add icon entry in `SettingsIcon.swift`**

Open `RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsIcon.swift` and add a new icon entry following the existing pattern, mapping the new `SettingsTab.codePreview` case (or whichever discriminator the file uses) to the SF Symbol `text.alignleft`.

- [ ] **Step 5: Build the settings UI**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerPackages
swift build --target RuntimeViewerSettingsUI 2>&1 | xcsift
```

Expected: build succeeds. If `SettingsTab` enum is exhaustive-switched anywhere, fix the missing case site to handle `.codePreview`.

- [ ] **Step 6: Commit**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
git add RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/Components/CodePreviewSettingsView.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsRootView.swift \
        RuntimeViewerPackages/Sources/RuntimeViewerSettingsUI/SettingsIcon.swift
git commit -m "feat(settings-ui): add Editor tab with line-numbers and minimap toggles"
```

---

## Task 11: Wire `CodePreviewContainerView` into AppKit `ContentTextViewController`

**Files:**
- Modify: `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift`

The integration:
1. Replace the `(scrollView, textView)` lazy tuple with a single `codePreviewContainer`.
2. Provide a `ThemeProfile` → `CodePreviewTheme` adapter.
3. Subscribe to `Settings.codePreview` and bind to container's visibility properties.

- [ ] **Step 1: Add the `ThemeProfileAdapter` private struct**

In `RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift`, add at the very bottom of the file (below `extension Selector { ... }`):

```swift
private struct ThemeProfileAdapter: CodePreviewTheme {
    let profile: ThemeProfile

    var backgroundColor: NSUIColor { profile.backgroundColor }
    var selectionBackgroundColor: NSUIColor { profile.selectionBackgroundColor }
    var commentColor: NSUIColor { profile.color(for: .comment) }
}
```

You will also need `import RuntimeViewerApplication` (already present) and `import Semantic` if `SemanticType.comment` requires it. Check the existing imports first — `ContentTextViewModel` uses `SemanticType` so the type is reachable.

- [ ] **Step 2: Replace `(scrollView, textView)` with `codePreviewContainer`**

Replace the existing block:
```swift
private let (scrollView, textView): (NSScrollView, ContentTextView) = {
    let scrollView = NSScrollView()
    let textView = ContentTextView(usingTextLayoutManager: true)

    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false

    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.drawsBackground = true
    scrollView.contentView.drawsBackground = true
    scrollView.documentView = textView

    textView.isRichText = false
    textView.usesRuler = false
    textView.usesInspectorBar = false
    textView.allowsDocumentBackgroundColorChange = false
    textView.importsGraphics = false
    textView.usesFontPanel = false
    textView.isVerticallyResizable = true
    textView.autoresizingMask = [.width, .height]

    return (scrollView, textView)
}()
```

With:
```swift
private let codePreviewContainer = CodePreviewContainerView(textViewType: ContentTextView.self)

private var textView: ContentTextView { codePreviewContainer.textView as! ContentTextView }
```

- [ ] **Step 3: Update `viewDidLoad()`**

Replace the existing `viewDidLoad()` body with:

```swift
    override func viewDidLoad() {
        super.viewDidLoad()

        contentView.hierarchy {
            codePreviewContainer
        }

        codePreviewContainer.snp.makeConstraints { make in
            make.top.equalToSuperview()
            make.leading.trailing.bottom.equalTo(view.safeAreaLayoutGuide)
        }

        textView.do {
            $0.isRichText = false
            $0.usesRuler = false
            $0.usesInspectorBar = false
            $0.allowsDocumentBackgroundColorChange = false
            $0.importsGraphics = false
            $0.usesFontPanel = false
            $0.isSelectable = true
            $0.isEditable = false
            $0.usesFindBar = true
            $0.textContainerInset = .init(width: 5.0, height: 5.0)
            $0.linkTextAttributes = [:]
            $0.delegate = self
        }
    }
```

- [ ] **Step 4: Update `setupBindings(for:)` — attributedString and theme drivers**

In the existing `setupBindings(for:)`, replace:
```swift
        output.attributedString.drive(with: self) { target, attributedString in
            target.textView.textStorage?.setAttributedString(attributedString)
        }
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self) {
            ($0.contentView as? UXView)?.backgroundColor = $1.backgroundColor
            $0.textView.backgroundColor = $1.backgroundColor
            $0.scrollView.backgroundColor = $1.backgroundColor
        }
        .disposed(by: rx.disposeBag)
```

With:
```swift
        output.attributedString.drive(with: self) { target, attributedString in
            target.codePreviewContainer.attributedString = attributedString
        }
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self) { target, theme in
            (target.contentView as? UXView)?.backgroundColor = theme.backgroundColor
            target.codePreviewContainer.theme = ThemeProfileAdapter(profile: theme)
        }
        .disposed(by: rx.disposeBag)
```

- [ ] **Step 5: Add Settings.codePreview subscription**

Append the following inside `setupBindings(for:)`, after the existing `eventMonitor.addLocalMonitorForEvents` block:

```swift
        let codePreviewObservable = Observable<RuntimeViewerSettings.Settings.CodePreview>.create { observer in
            let settings = RuntimeViewerSettings.Settings.shared
            observer.onNext(settings.codePreview)
            func observe() {
                withObservationTracking {
                    _ = settings.codePreview
                } onChange: {
                    DispatchQueue.main.async {
                        observer.onNext(settings.codePreview)
                        observe()
                    }
                }
            }
            observe()
            return Disposables.create()
        }

        codePreviewObservable
            .observeOnMainScheduler()
            .subscribeOnNext { [weak self] config in
                guard let self else { return }
                codePreviewContainer.showsLineNumbers = config.showsLineNumbers
                codePreviewContainer.showsMinimap = config.showsMinimap
            }
            .disposed(by: rx.disposeBag)
```

If `RuntimeViewerSettings` is not yet imported at the top of the file, add `@preconcurrency import RuntimeViewerSettings` next to the existing imports (matching `ContentTextViewModel.swift`'s style).

- [ ] **Step 6: Verify the file builds via Xcode**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewer macOS" \
                 -configuration Debug \
                 -destination 'generic/platform=macOS' 2>&1 | xcsift
```

Expected: build succeeds. Common error patterns and fixes:
  - "no such module 'RuntimeViewerSettings'" — Add the import.
  - "Cannot convert value of type 'CodePreviewContainerView' to expected argument type 'NSView'" — Make sure `contentView.hierarchy` accepts NSView; `CodePreviewContainerView` inherits NSUIView which is NSView on AppKit, so this should work.
  - "Type 'ContentTextView' has no member 'textStorage'" — your edit removed too much; restore the textView access pattern using `codePreviewContainer.textView`.

- [ ] **Step 7: Commit**

```bash
git add RuntimeViewerUsingAppKit/RuntimeViewerUsingAppKit/Content/ContentTextViewController.swift
git commit -m "feat(macos): wire CodePreviewContainerView into ContentTextViewController"
```

---

## Task 12: Wire `CodePreviewContainerView` into UIKit `ContentTextViewController`

**Files:**
- Modify: `RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentTextViewController.swift`

UIKit version mirrors the AppKit changes but: (a) no Settings binding (Settings is AppKit-only), (b) no `eventMonitor`, (c) selection-change is forwarded via `UITextViewDelegate` rather than NotificationCenter.

- [ ] **Step 1: Read the current UIKit `ContentTextViewController`**

```bash
cat /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer/RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentTextViewController.swift
```

This step is informational. Note the existing setup — its structure mirrors the AppKit version but uses `UITextView` and `UIScrollView`.

- [ ] **Step 2: Add `ThemeProfileAdapter` private struct**

At the very bottom of the UIKit `ContentTextViewController.swift` file, add:

```swift
private struct ThemeProfileAdapter: CodePreviewTheme {
    let profile: ThemeProfile

    var backgroundColor: NSUIColor { profile.backgroundColor }
    var selectionBackgroundColor: NSUIColor { profile.selectionBackgroundColor }
    var commentColor: NSUIColor { profile.color(for: .comment) }
}
```

If `Semantic`, `RuntimeViewerUI`, `RuntimeViewerApplication`, or `UIFoundation` aren't imported at the top of the file, add the missing imports (matching the AppKit version).

- [ ] **Step 3: Replace existing scrollView/textView storage with `codePreviewContainer`**

Locate the existing `scrollView` and `textView` (or equivalent) properties. Replace with:

```swift
private let codePreviewContainer = CodePreviewContainerView(textViewType: ContentTextView.self)

private var textView: ContentTextView { codePreviewContainer.textView as! ContentTextView }
```

(If the UIKit file doesn't define a `ContentTextView` subclass yet, use `UITextView.self` instead and update accessors accordingly.)

- [ ] **Step 4: Update `viewDidLoad()` to embed the container**

Replace the existing `viewDidLoad()` body with:

```swift
    override func viewDidLoad() {
        super.viewDidLoad()

        view.addSubview(codePreviewContainer)
        codePreviewContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            codePreviewContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            codePreviewContainer.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            codePreviewContainer.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            codePreviewContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
        ])

        textView.isEditable = false
        textView.isSelectable = true
        textView.delegate = self
    }
```

(If the existing UIKit controller already has different `view.addSubview` plumbing or uses SnapKit, follow that pattern but route to `codePreviewContainer`.)

- [ ] **Step 5: Update `setupBindings(for:)` to drive container instead of textView/scrollView directly**

In the existing `setupBindings(for:)`, replace the bindings that currently set `textView.attributedText` / `textView.backgroundColor` / `scrollView.backgroundColor` with:

```swift
        output.attributedString.drive(with: self) { target, attributedString in
            target.codePreviewContainer.attributedString = attributedString
        }
        .disposed(by: rx.disposeBag)

        output.theme.drive(with: self) { target, theme in
            target.codePreviewContainer.theme = ThemeProfileAdapter(profile: theme)
            target.view.backgroundColor = theme.backgroundColor
        }
        .disposed(by: rx.disposeBag)
```

- [ ] **Step 6: Add `textViewDidChangeSelection(_:)` forwarding for gutter highlight**

In the controller's `UITextViewDelegate` conformance:

```swift
    func textViewDidChangeSelection(_ textView: UITextView) {
        codePreviewContainer.updateGutterHighlight()
    }
```

If a `textViewDidChangeSelection(_:)` already exists, append the call to its body.

- [ ] **Step 7: Skip Settings subscription**

UIKit has no `RuntimeViewerSettings` integration (mirrors the existing pattern in `ContentTextViewModel` where the `transformerObservable` is gated behind `#if canImport(AppKit)`). The container's default values (`showsLineNumbers = true`, `showsMinimap = true`) apply.

- [ ] **Step 8: Build**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewerUsingUIKit" \
                 -configuration Debug \
                 -destination 'generic/platform=iOS Simulator' 2>&1 | xcsift
```

Expected: build succeeds.

- [ ] **Step 9: Commit**

```bash
git add RuntimeViewerUsingUIKit/RuntimeViewerUsingUIKit/Content/ContentTextViewController.swift
git commit -m "feat(ios): wire CodePreviewContainerView into ContentTextViewController"
```

---

## Task 13: Manual smoke test on macOS

**Files:** none (manual verification of running app)

- [ ] **Step 1: Launch the macOS app**

```bash
cd /Volumes/Repositories/Private/Org/MxIris-Reverse-Engineering/RuntimeViewer
xcodebuild build -workspace ../MxIris-Reverse-Engineering.xcworkspace \
                 -scheme "RuntimeViewer macOS" \
                 -configuration Debug \
                 -destination 'platform=macOS,arch=arm64' 2>&1 | xcsift
open ./DerivedData/RuntimeViewer/Build/Products/Debug/RuntimeViewer.app
```

If the build path differs, adjust per the workspace's actual `DerivedData` location. Alternatively, run from Xcode directly via `Cmd+R`.

- [ ] **Step 2: Verify gutter renders for a short interface**

Open any small Objective-C class (e.g., `NSObject`). Confirm:
- Line numbers visible on the left.
- Numbers right-aligned, monospaced.
- Background slightly different shade from the main text background.

- [ ] **Step 3: Verify minimap renders**

Open a medium-length class (e.g., `NSView`). Confirm:
- Minimap visible on the right.
- Coloured boxes match the syntax highlighting.
- A semi-translucent rectangle (viewport indicator) sits over the visible region.

- [ ] **Step 4: Verify scroll synchronization**

Scroll the main text view. Confirm:
- Viewport indicator moves down/up proportionally.
- Minimap content also scrolls (when the document is taller than minimap visible area).

- [ ] **Step 5: Verify viewport indicator drag**

Click and drag the viewport indicator down. Confirm:
- Main view scrolls with the indicator.
- Indicator changes alpha to the active state during drag.
- No flicker / no feedback loop.

- [ ] **Step 6: Verify minimap click-to-jump**

Click on the minimap **outside** the viewport indicator. Confirm:
- Main view jumps to that position with the click target near vertical center.

- [ ] **Step 7: Verify gutter line click + current-line highlight**

Click a gutter line number. Confirm:
- That entire line is selected in the text view (visible selection range).
- The gutter cell for that line shows the current-line highlight band.

Click in the text body to set just an insertion point. Confirm:
- Gutter highlights the line containing the insertion point (band visible behind the line number).

- [ ] **Step 8: Verify Settings toggles**

Open Settings → Editor (or whichever tab name was registered). Confirm both toggles default to ON. Toggle each off:
- Show Line Numbers: gutter disappears immediately.
- Show Minimap: minimap disappears immediately.

Toggle back on, confirm they reappear. Quit and relaunch the app — toggle states should persist.

- [ ] **Step 9: Verify theme switches**

Settings → General → Appearance: switch Light → Dark → Light. Confirm:
- Gutter background tints in the opposite direction each time.
- Line number text remains visible in both modes.
- Minimap background and viewport indicator follow the theme.

- [ ] **Step 10: Verify existing features unbroken**

- Cmd+Click on a type name in the body still navigates to the definition.
- Cmd+F opens the find bar; search highlights within the text view.
- Right-click in the text body still shows the existing context menu (cut/copy/paste/jump-to-definition).

- [ ] **Step 11: Long document smoke**

Open a very large class (e.g., `NSWindow` / `UIViewController` if those produce long dumps). Watch for:
- Initial render time (subjectively below ~500ms, no visible UI freeze).
- Smooth scrolling.
- Minimap viewport box correctly sized and positioned.

If any of the above fails, file the issue per Risk R1 in the design spec; do not block this plan.

- [ ] **Step 12: Commit any test-fixture additions (if added)**

If you added any test data or fixtures during smoke testing, commit them:

```bash
git add <fixture-files>
git commit -m "chore(test): add smoke-test fixtures for code preview"
```

Otherwise, skip this step.

---

## Done

All tasks complete. The `feature/code-preview-gutter-minimap` branch should now have:
- The original spec commit (`3e66842`).
- ~12 feature commits (one per task that produced code).

Push when ready:

```bash
git push -u origin feature/code-preview-gutter-minimap
```

Open a PR against `main`:

```bash
gh pr create --title "feat: add Gutter and Minimap to ContentTextViewController" \
             --body "$(cat <<'EOF'
## Summary
- Port a trimmed cross-platform Gutter (line numbers + current-line highlight + click-to-select) and Minimap (scaled overview + draggable viewport indicator) from mchakravarty/CodeEditorView into a new `CodePreviewContainerView` in `RuntimeViewerUI`
- Wire the container into both `ContentTextViewController` instances (AppKit + UIKit) in place of the bare `NSScrollView`/`NSTextView` pair
- Add Settings toggles `Show Line Numbers` and `Show Minimap` (Editor tab); colors derive from the existing `ThemeProfile` via extension

## Test plan
- [ ] Run `swift test --filter LineMapTests` — all pass
- [ ] Run `swift test --filter ThemeColorDerivationTests` — all pass
- [ ] Smoke-test macOS app per Task 13 (steps 2–11)
- [ ] Smoke-test iOS app on simulator (gutter + minimap render and respond to scroll/drag)

## Design
See `Documentations/Plans/2026-05-05-codeeditorview-gutter-minimap-port-design.md`.
EOF
)"
```
