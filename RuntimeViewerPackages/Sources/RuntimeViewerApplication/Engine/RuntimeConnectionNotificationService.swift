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
                case .catalystHelperUnavailable:
                    // Logged by the manager; no user-facing notification today.
                    break
                }
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
