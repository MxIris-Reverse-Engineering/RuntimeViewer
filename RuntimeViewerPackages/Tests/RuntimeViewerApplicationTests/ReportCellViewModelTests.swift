import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerApplication

/// A Report navigator row publishes what it shows as one appearance: an update that changes
/// several parts of the row is one event, and an update that changes nothing is none. The cell
/// redraws on every event, and a running row is updated many times a second.
@Suite("ReportCellViewModel")
@MainActor
struct ReportCellViewModelTests {
    private static let foundationPath = "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation"

    @Test("an update that changes several parts of a row publishes them in one event")
    func updatePublishesOneEvent() {
        let cellViewModel = ReportCellViewModel(identifier: .corpusBuild(imagePath: Self.foundationPath))
        cellViewModel.update(icon: ReportOutline.corpusIcon, title: "Foundation", detail: "Waiting", toolTip: Self.foundationPath)
        let recorder = AppearanceRecorder(observing: cellViewModel)

        cellViewModel.update(icon: ReportOutline.corpusIcon, title: "Foundation", detail: "37% · 950 of 2559", status: .running, toolTip: Self.foundationPath)

        #expect(recorder.publishedAppearances == [
            ReportCellViewModel.Appearance(icon: ReportOutline.corpusIcon, title: "Foundation", detail: "37% · 950 of 2559", status: .running, toolTip: Self.foundationPath),
        ])
    }

    @Test("an update that repeats what a row already shows publishes nothing")
    func repeatedUpdatePublishesNothing() {
        let cellViewModel = ReportCellViewModel(identifier: .corpusBuild(imagePath: Self.foundationPath))
        cellViewModel.update(icon: ReportOutline.corpusIcon, title: "Foundation", detail: "Waiting", toolTip: Self.foundationPath)
        let recorder = AppearanceRecorder(observing: cellViewModel)

        cellViewModel.update(icon: ReportOutline.corpusIcon, title: "Foundation", detail: "Waiting", toolTip: Self.foundationPath)

        #expect(recorder.publishedAppearances.isEmpty)
    }
}

/// Records what `$appearance` publishes after the recorder subscribes. The relay emits
/// synchronously, so the record is complete as soon as `update` returns.
@MainActor
private final class AppearanceRecorder {
    private(set) var publishedAppearances: [ReportCellViewModel.Appearance] = []

    private let disposeBag = DisposeBag()

    init(observing cellViewModel: ReportCellViewModel) {
        cellViewModel.$appearance
            .skip(1) // the relay replays the current appearance on subscribe
            .subscribeOnNext { [weak self] appearance in
                guard let self else { return }
                publishedAppearances.append(appearance)
            }
            .disposed(by: disposeBag)
    }
}
