#if os(macOS)
import Foundation
import FoundationToolbox
import UserNotifications
import RuntimeViewerSettings
import RuntimeViewerCore
import RuntimeViewerCommunication
import Dependencies

/// Service responsible for sending local notifications for runtime connection events.
@Loggable
@MainActor
public final class RuntimeConnectionNotificationService: NSObject {
    public static let shared = RuntimeConnectionNotificationService()

    private let notificationCenter = UNUserNotificationCenter.current()

    private override init() {
        super.init()
        notificationCenter.delegate = self
        requestAuthorization()
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
        let settings = Settings.shared.notifications
        guard settings.isEnabled, settings.showOnConnect else { return }

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
        let settings = Settings.shared.notifications
        guard settings.isEnabled, settings.showOnDisconnect else { return }

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
private enum RuntimeConnectionNotificationServiceKey: @MainActor DependencyKey {
    static let liveValue = RuntimeConnectionNotificationService.shared
}

@MainActor
extension DependencyValues {
    public var runtimeConnectionNotificationService: RuntimeConnectionNotificationService {
        get { self[RuntimeConnectionNotificationServiceKey.self] }
        set { self[RuntimeConnectionNotificationServiceKey.self] = newValue }
    }
}
#endif
