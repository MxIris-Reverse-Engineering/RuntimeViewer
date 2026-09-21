#if os(macOS)
import Combine
import Foundation
import FoundationToolbox
import UserNotifications
import RuntimeViewerSettings
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import Dependencies
import DependenciesMacros

/// Turns `RuntimeEngineManager`'s connection events into user notifications.
///
/// Lives in the app layer, not next to the manager: `UNUserNotificationCenter`
/// needs an application bundle behind the process, and the manager is also
/// linked by processes that have none.
@Loggable
@MainActor
public final class RuntimeConnectionNotificationService: NSObject {
    fileprivate static let shared = RuntimeConnectionNotificationService()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    private let notificationCenter = UNUserNotificationCenter.current()

    private var eventSubscription: AnyCancellable?

    /// Subscription to the "My Mac" engine's state; see ``observeLocalRuntimeRestarts()``.
    private var localRuntimeSubscription: AnyCancellable?

    /// The local engine reported `.disconnected` since it was last
    /// `.connected`, so the next `.connected` is a restart, not the first
    /// connection.
    private var localRuntimeWasDisconnected = false

    private override init() {
        super.init()
        notificationCenter.delegate = self
        requestAuthorization()
    }

    // MARK: - Lifecycle

    /// Subscribes to the manager's events. Call once at launch, before the run
    /// loop reaches the connection tasks the manager scheduled on creation:
    /// events are not replayed, so a late subscriber misses the first
    /// connections.
    public func start() {
        guard eventSubscription == nil else { return }
        eventSubscription = runtimeEngineManager.eventPublisher
            .sink { [weak self] event in
                guard let self else { return }
                switch event {
                case .engineConnected(let engine):
                    notifyConnected(source: engine.source)
                case .hostDisconnected(let source, let error):
                    notifyDisconnected(source: source, error: error)
                case .catalystHelperUnavailable(let error):
                    notifyCatalystHelperUnavailable(error: error)
                }
            }
        observeLocalRuntimeRestarts()
    }

    /// Watches "My Mac" for the one edge the manager never reports: the
    /// local-runtime XPC service exiting and the same engine reattaching to a
    /// relaunched one. The manager does not observe the local engine at all —
    /// it is the one engine a disconnect must not remove — and the engine's
    /// own state tells the whole story: `.disconnected` while the service is
    /// gone, `.connected` again once the connection reattached. The first
    /// `.connected` is not announced: "My Mac" being available is not news.
    private func observeLocalRuntimeRestarts() {
        localRuntimeSubscription = RuntimeEngine.local.statePublisher
            .sink { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleLocalRuntimeStateChange(state)
                }
            }
    }

    private func handleLocalRuntimeStateChange(_ state: RuntimeEngine.State) {
        switch state {
        case .disconnected:
            localRuntimeWasDisconnected = true
        case .connected:
            guard localRuntimeWasDisconnected else { return }
            localRuntimeWasDisconnected = false
            #log(.info, "Local runtime engine reattached to a relaunched XPC service")
            notifyLocalRuntimeRestarted()
        case .initializing, .connecting, .localOnly:
            break
        }
    }

    // MARK: - Authorization

    private func requestAuthorization() {
        notificationCenter.requestAuthorization(options: [.alert]) { granted, error in
            if let error {
                #log(.error,"Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if granted {
                #log(.info,"Notification authorization granted")
            } else {
                #log(.info,"Notification authorization denied")
            }
        }
    }

    // MARK: - Connection Events

    /// Sends a notification when a runtime engine is connected.
    /// - Parameter source: The runtime source that was connected.
    public func notifyConnected(source: RuntimeSource) {
        @Dependency(\.settings) var settings
        let notificationSettings = settings.notifications
        guard notificationSettings.isEnabled, notificationSettings.showOnConnect else { return }

        let content = UNMutableNotificationContent()
        content.title = "Connected"
        content.body = "Successfully connected to \(source.displayName)"

        sendNotification(identifier: "connection.connected.\(source.identifier)", content: content)
    }

    /// Sends a notification when a runtime engine is disconnected.
    /// - Parameters:
    ///   - source: The runtime source that was disconnected.
    ///   - error: Optional error if disconnection was unexpected.
    public func notifyDisconnected(source: RuntimeSource, error: Error?) {
        @Dependency(\.settings) var settings
        let notificationSettings = settings.notifications
        guard notificationSettings.isEnabled, notificationSettings.showOnDisconnect else { return }

        let content = UNMutableNotificationContent()
        content.title = "Disconnected"

        if let error {
            content.body = "Lost connection to \(source.displayName): \(error.localizedDescription)"
        } else {
            content.body = "Disconnected from \(source.displayName)"
        }

        sendNotification(identifier: "connection.disconnected.\(source.identifier)", content: content)
    }

    /// Sends a notification when the Mac Catalyst engine could not be brought
    /// up. Without it the failure is invisible: the engine is simply absent
    /// from the menu, and before the handshake was confirmed it was worse — an
    /// entry that loaded forever.
    public func notifyCatalystHelperUnavailable(error: Error) {
        @Dependency(\.settings) var settings
        guard settings.notifications.isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Mac Catalyst Runtime Unavailable"
        content.body = error.localizedDescription

        sendNotification(identifier: "connection.catalystUnavailable", content: content)
    }

    /// Sends a notification when the local-runtime XPC service was relaunched.
    ///
    /// The engine stays in the source menu and every document on it walks
    /// itself back to the image list, so without this the only trace of what
    /// happened would be the images the user loaded being silently gone.
    /// Gated on notifications being enabled at all, not on the connect /
    /// disconnect toggles: this is neither, and it is the one event here the
    /// user has to act on.
    public func notifyLocalRuntimeRestarted() {
        @Dependency(\.settings) var settings
        guard settings.notifications.isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Local Runtime Restarted"
        content.body = "The local runtime service exited and was started again. Images loaded in My Mac have to be loaded again."

        sendNotification(identifier: "connection.localRuntimeRestarted", content: content)
    }

    // MARK: - Private

    private func sendNotification(identifier: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil // Deliver immediately
        )

        notificationCenter.add(request) { error in
            if let error {
                #log(.error,"Failed to send notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

@MainActor
extension RuntimeConnectionNotificationService: @MainActor UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show notification even when app is in foreground
        completionHandler([.banner])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Handle notification tap if needed
        completionHandler()
    }
}

// MARK: - RuntimeSource Extension

extension RuntimeSource {
    fileprivate var displayName: String {
        switch self {
        case .local:
            return "Local Runtime"
        case .macCatalystClient:
            return "Mac Catalyst Runtime"
        case .bonjour(let name, _, _):
            return "Bonjour: \(name)"
        default:
            return description
        }
    }

}

// MARK: - Dependencies

@MainActor
extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeConnectionNotificationService.shared })
    public var runtimeConnectionNotificationService: RuntimeConnectionNotificationService
}
#endif
