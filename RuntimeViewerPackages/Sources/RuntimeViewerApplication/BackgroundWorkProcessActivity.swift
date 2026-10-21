import Foundation
import FoundationToolbox
import RuntimeViewerArchitectures

/// Keeps the app out of App Nap while an engine's background work is in progress: an indexing
/// batch, a corpus queued or being printed, cross references queued or being prepared —
/// `RuntimeEngineBackgroundWork.isWorkInProgress`. One per engine's work, which holds it for as
/// long as a document is on the engine.
///
/// That work runs in the local-runtime XPC service — or, for a Mac Catalyst document, the Mac
/// Catalyst service — which launchd starts as an adaptive job: it runs at full speed while a
/// request from an app that donates importance is waiting on it, and in the Darwin background
/// band otherwise — priority 4, efficiency cores only. An app in App Nap
/// donates nothing, so once the user had been in another app for about thirty seconds, every
/// request the app had waiting stopped boosting the service, and SwiftUI's corpus took 187
/// seconds to print instead of 18. Holding a user-initiated activity keeps the app out of App Nap
/// for as long as the work lasts, and with it the boost its waiting requests give the service.
/// The activity is let go as soon as the work ends, so an idle app naps as before; idle system
/// sleep stays allowed, as nothing here is worth keeping the Mac awake for. The activity covers
/// the whole process, so one per engine with work is as good as one per document on it.
///
/// Background: `Documentations/ResolvedIssues/2026-10-13-background-work-throttled-by-app-nap.md`.
@MainActor
@Loggable(.private)
public final class BackgroundWorkProcessActivity {
    static let options: ProcessInfo.ActivityOptions = .userInitiatedAllowingIdleSystemSleep

    static let reason = "Indexing images, building their searchable interfaces and preparing their cross references"

    private let scheduler: any ProcessActivityScheduling

    /// The activity held while work is in progress, `nil` otherwise.
    private var activity: (any NSObjectProtocol)?

    private var disposeBag = DisposeBag()

    /// `close()` has run. Each report reaches the activity a main-actor turn after it is made, so
    /// one can still arrive after the close; this is what turns it away.
    private var isClosed = false

    /// Whether an activity is held. Test seam.
    var isHoldingActivity: Bool {
        activity != nil
    }

    init(isWorkInProgress: Driver<Bool>, scheduler: any ProcessActivityScheduling) {
        self.scheduler = scheduler
        isWorkInProgress
            .driveOnNextMainActor { [weak self] isWorkInProgress in
                guard let self, !isClosed else { return }
                update(isWorkInProgress: isWorkInProgress)
            }
            .disposed(by: disposeBag)
    }

    deinit {
        if let activity {
            scheduler.endActivity(activity)
        }
    }

    /// The engine's work closed, its last document gone: the activity is let go, and no later
    /// report takes it again — not even one made before the close and still on its way. The
    /// documents that left can still hold the work, so `deinit` is too late to count on.
    func close() {
        isClosed = true
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
