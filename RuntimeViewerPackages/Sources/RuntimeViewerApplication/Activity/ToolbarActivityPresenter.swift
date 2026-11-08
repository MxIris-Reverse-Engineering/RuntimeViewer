import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerUI

/// What a window's activity display shows: the activity reports of the engine the document is on,
/// picked and timed the way Xcode's activity view picks and times them.
///
/// The reports are the engine's (`RuntimeEngineActivityReporter`); the choice and its timing are
/// the window's own (`ActivityReportSelector`), as each Xcode window has an activity data source of
/// its own over the workspace's reports. A document that moves to another engine starts over:
/// idle, ready from the moment it moved.
@MainActor
public final class ToolbarActivityPresenter {
    /// How often the display takes a new state at most — Xcode's `IDEActivityViewUpdateThreshold`.
    /// The first change after a quiet second shows at once, the last one of a busy second at its end.
    static let updateThreshold: RxTimeInterval = .seconds(1)

    /// The display's state.
    public let state: Driver<ToolbarActivityState>

    public convenience init(documentState: DocumentState) {
        self.init(documentState: documentState, scheduler: MainScheduler.instance, now: Date.init)
    }

    init(documentState: DocumentState, scheduler: SchedulerType, now: @escaping () -> Date) {
        state = documentState.$runtimeEngineSession.asObservable()
            .flatMapLatest { session -> Observable<ToolbarActivityState> in
                MainActor.assumeIsolated {
                    let snapshots = Self.snapshots(of: session)
                    return Self.states(
                        from: snapshots,
                        sourceName: session.engine.source.description,
                        readyDate: now(),
                        scheduler: scheduler,
                        now: now
                    )
                }
            }
            .distinctUntilChanged()
            .throttle(Self.updateThreshold, latest: true, scheduler: scheduler)
            .asDriver(onErrorDriveWith: .empty())
    }

    /// The reports of the work `session` holds, as one: the engine's own and, while it borrows shared
    /// cache images, those of every engine it borrows from — what the document's Report lists.
    static func snapshots(of session: RuntimeEngineSession) -> Observable<ActivityReportsSnapshot> {
        let reporters = session.backgroundWorks.map(\.activityReporter)
        guard let firstReporter = reporters.first else { return .just(.empty) }
        guard reporters.count > 1 else { return firstReporter.$snapshot.asObservable() }
        return Observable.combineLatest(reporters.map { $0.$snapshot.asObservable() }) { snapshots in
            ActivityReportsSnapshot.merged(snapshots)
        }
    }

    /// The display's states for one engine's snapshots, before the update threshold: one for every
    /// snapshot, and one more whenever the selection can change on its own — a run reaching its
    /// display delay, the report on screen reaching its minimum time.
    static func states(
        from snapshots: Observable<ActivityReportsSnapshot>,
        sourceName: String,
        readyDate: Date,
        scheduler: SchedulerType,
        now: @escaping () -> Date
    ) -> Observable<ToolbarActivityState> {
        Observable.create { observer in
            var selector = ActivityReportSelector()
            var latestSnapshot = ActivityReportsSnapshot.empty
            let pendingUpdate = SerialDisposable()

            func update() {
                let selection = selector.update(with: latestSnapshot, now: now())
                observer.onNext(.make(for: selection, sourceName: sourceName, readyDate: readyDate))
                guard let nextUpdateDate = selection.nextUpdateDate else {
                    pendingUpdate.disposable = Disposables.create()
                    return
                }
                // A millisecond late rather than early, so that the date has passed when the update runs.
                let delayInMilliseconds = Int((max(nextUpdateDate.timeIntervalSince(now()), 0) * 1000).rounded(.up)) + 1
                pendingUpdate.disposable = scheduler.scheduleRelative((), dueTime: .milliseconds(delayInMilliseconds)) { _ in
                    update()
                    return Disposables.create()
                }
            }

            let subscription = snapshots.subscribeOnNext { snapshot in
                latestSnapshot = snapshot
                update()
            }
            return Disposables.create(subscription, pendingUpdate)
        }
    }
}
