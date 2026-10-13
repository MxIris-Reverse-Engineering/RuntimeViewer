import Foundation
import FoundationToolbox
import RuntimeViewerArchitectures

/// Keeps the app out of App Nap while a document has background work in progress: an indexing
/// batch, or a corpus queued or being printed — `DocumentState.reportActivity`.
///
/// That work runs in the local-runtime XPC service, which launchd starts as an adaptive job: it
/// runs at full speed while a request from an app that donates importance is waiting on it, and
/// in the Darwin background band otherwise — priority 4, efficiency cores only. An app in App Nap
/// donates nothing, so once the user had been in another app for about thirty seconds, every
/// request the app had waiting stopped boosting the service, and SwiftUI's corpus took 187
/// seconds to print instead of 18. Holding a user-initiated activity keeps the app out of App Nap
/// for as long as the work lasts, and with it the boost its waiting requests give the service.
/// The activity is let go as soon as the work ends, so an idle document naps as before; idle
/// system sleep stays allowed, as nothing here is worth keeping the Mac awake for.
///
/// Background: `Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`.
@MainActor
@Loggable(.private)
public final class BackgroundWorkProcessActivity {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    static let reason = "Indexing images and building their searchable interfaces"

    private let scheduler: any ProcessActivityScheduling

    /// The activity held while work is in progress, `nil` otherwise.
    private var activity: (any NSObjectProtocol)?

    private var disposeBag = DisposeBag()

    /// Whether an activity is held. Test seam.
    var isHoldingActivity: Bool {
        activity != nil
    }

    init(isWorkInProgress: Driver<Bool>, scheduler: any ProcessActivityScheduling) {
        self.scheduler = scheduler
        isWorkInProgress
            .driveOnNextMainActor { [weak self] isWorkInProgress in
                guard let self else { return }
                update(isWorkInProgress: isWorkInProgress)
            }
            .disposed(by: disposeBag)
    }

    deinit {
        if let activity {
            scheduler.endActivity(activity)
        }
    }

    /// The document is closing: the activity is let go, and no later report takes it again.
    /// `DocumentState` can outlive its window, so `deinit` is too late to count on.
    func documentWillClose() {
        disposeBag = DisposeBag()
        update(isWorkInProgress: false)
    }

    private func update(isWorkInProgress: Bool) {
        if isWorkInProgress, activity == nil {
            activity = scheduler.beginActivity(options: Self.options, reason: Self.reason)
            #log(.info, "Background work started; holding a user-initiated activity to stay out of App Nap")
        } else if !isWorkInProgress, let activity {
            scheduler.endActivity(activity)
            self.activity = nil
            #log(.info, "Background work ended; released the activity")
        }
    }
}

/// What `BackgroundWorkProcessActivity` asks of `ProcessInfo`, so a test can see each activity
/// begin and end.
protocol ProcessActivityScheduling: AnyObject {
    func beginActivity(options: ProcessInfo.ActivityOptions, reason: String) -> any NSObjectProtocol

    func endActivity(_ activity: any NSObjectProtocol)
}

extension ProcessInfo: ProcessActivityScheduling {}
