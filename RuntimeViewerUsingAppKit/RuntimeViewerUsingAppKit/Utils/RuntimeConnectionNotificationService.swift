import Foundation
import FoundationToolbox
import UserNotifications
import RuntimeViewerSettings
import RuntimeViewerCore
import RuntimeViewerCommunication
import Dependencies

/// Service responsible for sending local notifications for runtime connection events.
public final class RuntimeConnectionNotificationService: NSObject, Loggable {
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
                Self.logger.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)")
            } else if granted {
                Self.logger.info("Notification authorization granted")
            } else {
                Self.logger.info("Notification authorization denied")
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
                Self.logger.error("Failed to send notification: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension RuntimeConnectionNotificationService: UNUserNotificationCenterDelegate {
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
        case .remote(let name, _, _):
            return name
        case .bonjourClient(let endpoint):
            return "Bonjour: \(endpoint.name)"
        case .bonjourServer(let name, _):
            return name
        case .macCatalystClient:
            return "Mac Catalyst Runtime"
        case .localSocketClient(let name, _):
            return name
        case .localSocketServer(let name, _):
            return name
        case .directTCPClient(let name, _, _):
            return name
        case .directTCPServer(let name, _):
            return name
        }
    }

    fileprivate var identifier: String {
        switch self {
        case .local:
            return "local"
        case .remote(_, let id, _):
            return id.rawValue
        case .bonjourClient(let endpoint):
            return "bonjour.\(endpoint.name)"
        case .bonjourServer(let name, _):
            return "bonjourServer.\(name)"
        case .macCatalystClient:
            return "macCatalyst"
        case .localSocketClient(_, let id):
            return id.rawValue
        case .localSocketServer(_, let id):
            return "localSocketServer.\(id.rawValue)"
        case .directTCPClient(let name, let host, let port):
            return "tcp.\(name).\(host).\(port)"
        case .directTCPServer(let name, let port):
            return "tcpServer.\(name).\(port)"
        }
    }
}

// MARK: - Dependencies

private enum RuntimeConnectionNotificationServiceKey: DependencyKey {
    static let liveValue = RuntimeConnectionNotificationService.shared
}

extension DependencyValues {
    public var runtimeConnectionNotificationService: RuntimeConnectionNotificationService {
        get { self[RuntimeConnectionNotificationServiceKey.self] }
        set { self[RuntimeConnectionNotificationServiceKey.self] = newValue }
    }
}
