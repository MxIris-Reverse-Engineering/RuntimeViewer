#if os(macOS)

import Foundation
import Testing
import RuntimeViewerArchitectures
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The Load Frameworks page and the diagnosis it shows (proposal
/// `isolated-framework-loading`).
@Suite("Framework load page")
@MainActor
struct FrameworkLoadViewModelTests {
    private static let fooPath = "/Applications/Example.app/Contents/Frameworks/Foo.framework/Versions/A/Foo"
    private static let barInstallName = "@rpath/Bar.framework/Versions/A/Bar"

    /// Foo links Bar, which is in Example.app's Frameworks; Foo's rpath is
    /// written for Example.app's executable.
    private static func diagnosis(withRemedy: Bool = true, fromMessageOnly: Bool = false) -> RuntimeImageLoadDiagnosis {
        RuntimeImageLoadDiagnosis(
            imagePath: fooPath,
            dyldMessage: "dlopen(\(fooPath), 0x0001): Library not loaded: \(barInstallName)",
            failure: .init(kind: .imageNotFound, missingInstallName: barInstallName, referencingImagePath: fooPath),
            dependencyChain: [.init(imagePath: fooPath, installName: barInstallName, resolvedPath: nil)],
            rpathSearches: [
                .init(ownerImagePath: fooPath, role: .loader, rpath: "@executable_path/../Frameworks", candidatePath: "/Service.xpc/Contents/Frameworks/Bar.framework/Versions/A/Bar", outcome: .noSuchFile),
                .init(ownerImagePath: "/Service.xpc/Contents/MacOS/Service", role: .mainExecutable, rpath: "@loader_path/../Frameworks", candidatePath: "/Service.xpc/Contents/Frameworks/Bar.framework/Versions/A/Bar", outcome: .noSuchFile),
            ],
            triedPaths: [.init(path: "/Service.xpc/Contents/Frameworks/Bar.framework/Versions/A/Bar", reason: "no such file")],
            notes: [
                .init(kind: .rpathExpectsHostExecutable, imagePath: fooPath, rpath: "@executable_path/../Frameworks"),
                .init(kind: .dependencyInHostApplication, imagePath: "/Applications/Example.app/Contents/Frameworks/Bar.framework/Versions/A/Bar", hostApplicationPath: "/Applications/Example.app"),
            ],
            remedy: withRemedy ? .init(hostApplicationPath: "/Applications/Example.app", searchPaths: [], imagePathsToLoadFirst: ["/Applications/Example.app/Contents/Frameworks/Bar.framework/Versions/A/Bar"]) : nil,
            processArchitecture: "arm64e",
            operatingSystemVersion: "macOS 27.2",
            isFromMessageOnly: fromMessageOnly
        )
    }

    // MARK: - The Presentation

    @Test("the summary names the missing image and the framework that links it")
    func presentationSummaryNamesTheMissingImageAndWhoLinksIt() {
        let presentation = ImageLoadDiagnosisPresentation(diagnosis: Self.diagnosis(), frameworkName: "Foo.framework")

        #expect(presentation.title == "Foo.framework couldn't be loaded")
        #expect(presentation.summary == "dyld couldn't find \(Self.barInstallName), which Foo.framework links.")
        #expect(presentation.tags == ["Unresolved @rpath", "arm64e · macOS 27.2", "Diagnosed in the process that tried the load"])
        #expect(presentation.chain == [.init(name: "Foo.framework", isMissing: false), .init(name: "Bar.framework", isMissing: true)])
        #expect(presentation.rpathRows.map(\.ownerRole) == ["loader", "main executable"])
    }

    @Test("the banner names the host app the dependency is in, and the button loads its frameworks")
    func presentationBannerNamesTheHostApplication() throws {
        let presentation = ImageLoadDiagnosisPresentation(diagnosis: Self.diagnosis(), frameworkName: "Foo.framework")

        let explanation = try #require(presentation.remedyExplanation)
        #expect(explanation.hasPrefix("Bar.framework is in /Applications/Example.app/Contents/Frameworks."))
        #expect(explanation.contains("@executable_path"))
        #expect(presentation.remedyTitle == "Load Example.app's Frameworks and Retry")
    }

    @Test("without a remedy there is no banner text, and a diagnosis from dyld's message says so")
    func presentationWithoutRemedy() {
        let presentation = ImageLoadDiagnosisPresentation(diagnosis: Self.diagnosis(withRemedy: false, fromMessageOnly: true), frameworkName: "Foo.framework")

        #expect(presentation.remedyExplanation == nil)
        #expect(presentation.remedyTitle == nil)
        #expect(presentation.tags.last?.hasPrefix("From dyld's message only") == true)
    }

    @Test("the text to copy holds every section and dyld's message")
    func presentationCopyTextHoldsEverySection() {
        let presentation = ImageLoadDiagnosisPresentation(diagnosis: Self.diagnosis(), frameworkName: "Foo.framework")

        for part in ["Foo.framework couldn't be loaded", "Dependency chain: Foo.framework → Bar.framework (missing)", "Where it looked:", "Why:", "Paths dyld tried:", "dyld message:", Self.barInstallName] {
            #expect(presentation.copyText.contains(part), "missing: \(part)")
        }
    }

    // MARK: - The Page

    @Test("the page follows the loader: loading with its place in the request, the failure with its buttons, the instance stopped")
    func pageFollowsTheLoaderState() {
        let frameworkURL = URL(fileURLWithPath: "/A/Foo.framework")

        #expect(FrameworkLoadViewModel<MainRoute>.page(for: .idle, canClose: false) == .none)
        #expect(FrameworkLoadViewModel<MainRoute>.page(for: .loading(.init(frameworkURL: frameworkURL, position: 2, count: 3)), canClose: false)
            == .loading(title: "Loading Foo.framework…", detail: "2 of 3"))
        guard case .failure(_, let actions) = FrameworkLoadViewModel<MainRoute>.page(
            for: .failed(.init(frameworkURL: frameworkURL, diagnosis: Self.diagnosis(), remainingFrameworkURLs: [], offersRemedies: true)),
            canClose: false
        ) else {
            Issue.record("not a failure page")
            return
        }
        #expect(actions == FrameworkLoadPageActions(canRetry: true, canApplyRemedy: true, canChooseHostApplication: true, canAddSearchPath: true, canClose: false))
        guard case .instanceStopped(_, let detail) = FrameworkLoadViewModel<MainRoute>.page(
            for: .instanceStopped(.init(frameworkURLs: [frameworkURL], interruptedFrameworkURL: frameworkURL)),
            canClose: false
        ) else {
            Issue.record("not an instance stopped page")
            return
        }
        #expect(detail.contains("Foo.framework"))
    }

    @Test("a sheet over another engine offers no retry and no remedy, only closing")
    func sheetPresentationHasNoRetryOrRemedy() {
        let page = FrameworkLoadViewModel<MainRoute>.page(
            for: .failed(.init(frameworkURL: URL(fileURLWithPath: "/A/Foo.framework"), diagnosis: Self.diagnosis(), remainingFrameworkURLs: [], offersRemedies: false)),
            canClose: true
        )

        guard case .failure(_, let actions) = page else {
            Issue.record("not a failure page")
            return
        }
        #expect(actions == FrameworkLoadPageActions(canRetry: false, canApplyRemedy: false, canChooseHostApplication: false, canAddSearchPath: false, canClose: true))
    }

    @Test("Copy Diagnosis copies the text, Show in Finder shows the image, and Close dismisses the sheet")
    func buttonsCopyRevealAndClose() async throws {
        let environment = ViewModelTestEnvironment()
        let router = MockRouter<MainRoute>()
        let loader = environment.documentState.frameworkLoader
        loader.imageLoading = FrameworkLoader.ImageLoading(
            loadImage: { _, imagePath in
                throw RuntimeImageLoadError(dyldMessage: "refused", diagnosis: Self.diagnosis())
            },
            diagnoseImageLoad: { _, diagnosis, _, _ in diagnosis },
            waitUntilReady: { _ in }
        )
        let frameworkURL = URL(fileURLWithPath: "/usr/bin/true")
        await loader.load(frameworksAt: [frameworkURL])
        let viewModel = environment.make { FrameworkLoadViewModel<MainRoute>(documentState: environment.documentState, router: router, dismissRoute: .dismiss) }
        defer { withExtendedLifetime((viewModel, router)) {} }
        let copy = PublishRelay<Void>()
        let reveal = PublishRelay<Void>()
        let close = PublishRelay<Void>()
        let output = viewModel.transform(.init(
            retryClicked: .empty(),
            remedyClicked: .empty(),
            chooseHostApplicationClicked: .empty(),
            addSearchPathClicked: .empty(),
            hostApplicationChosen: .empty(),
            searchPathChosen: .empty(),
            loadAgainClicked: .empty(),
            copyDiagnosisClicked: copy.asSignal(),
            showInFinderClicked: reveal.asSignal(),
            closeClicked: close.asSignal()
        ))
        _ = try await nextValue(from: output.page) { page in
            if case .failure = page { return true }
            return false
        }

        copy.accept(())
        reveal.accept(())
        close.accept(())

        #expect(environment.pasteboard.copiedStrings.count == 1)
        #expect(environment.pasteboard.copiedStrings.first?.hasPrefix("true couldn't be loaded") == true)
        #expect(environment.finder.revealedFileURLs == [URL(fileURLWithPath: Self.fooPath)])
        #expect(router.triggeredRoutes.contains { $0.isDismiss })
    }
}

#endif
