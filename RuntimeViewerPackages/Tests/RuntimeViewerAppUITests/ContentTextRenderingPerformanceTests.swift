import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerAppUI
import RuntimeViewerAppTestingSupport

/// What showing a large interface costs since proposal `app-core-without-ui-models` split the work: the
/// view model prepares the interface (links, declared members, decorations), and only a pane that shows
/// themed text — the `NSTextView` one, iOS — themes it. Timed on Foundation's `NSString` with a wall
/// clock, 20 runs each, the median printed; the proposal's decision log has the numbers against the
/// code before the split. Off unless `RUNTIME_VIEWER_MEASURE_CONTENT_RENDERING` is set: timings say
/// nothing on a loaded machine, and a normal run should not wait for them.
@Suite(
    "Content text rendering cost",
    .enabled(if: ProcessInfo.processInfo.environment["RUNTIME_VIEWER_MEASURE_CONTENT_RENDERING"] != nil)
)
@MainActor
struct ContentTextRenderingPerformanceTests {
    private static let runCount = 20

    @Test("preparing and theming NSString's interface")
    func preparingAndThemingALargeInterface() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let object = try await engine.runtimeObject(named: "NSString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let fetchedInterface = try #require(try await engine.interface(for: object, options: .init()))
        let fetched = ContentTextViewModel.FetchedInterface(interfaceString: fetchedInterface.interfaceString, runtimeObject: object, commentStructure: nil)
        let theme = ResolvedTheme.fallback

        let preparing = Self.median(of: Self.runCount) { _ = ContentInterface.prepared(from: fetched) }
        let interface = ContentInterface.prepared(from: fetched)
        let theming = Self.median(of: Self.runCount) { _ = interface.attributedString(themedWith: theme) }

        print("content rendering: \((interface.string as NSString).length) UTF-16 units; prepare median \(preparing), theme median \(theming), both \(preparing + theming)")
        #expect(preparing > .zero && theming > .zero)
    }

    private static func median(of runCount: Int, _ work: () -> Void) -> Duration {
        var durations: [Duration] = []
        for _ in 0 ..< runCount {
            let start = ContinuousClock.now
            work()
            durations.append(ContinuousClock.now - start)
        }
        return durations.sorted()[runCount / 2]
    }
}
