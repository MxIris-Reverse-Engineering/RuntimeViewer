import Foundation
import Testing
import UserNotifications
import Dependencies
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerSettings

/// Which notifications the connection events turn into, read off a notification center of the test's
/// own (`UserNotificationCenterClient`, proposal `app-core-ui-split`): the system's needs an
/// application bundle behind the process, and a delivered notification would reach the developer's
/// screen.
@Suite("Connection notifications")
@MainActor
struct RuntimeConnectionNotificationServiceTests {
    private struct DeliveredNotification: Equatable, Sendable {
        let title: String
        let body: String
    }

    /// A notification center that grants permission and keeps what it is asked to deliver.
    private final class RecordingNotificationCenter: Sendable {
        let deliveredNotifications = LockIsolated<[DeliveredNotification]>([])

        var client: UserNotificationCenterClient {
            UserNotificationCenterClient(
                setDelegate: { _ in },
                requestAuthorization: { completion in completion(true, nil) },
                add: { [deliveredNotifications] request, completion in
                    deliveredNotifications.withValue {
                        $0.append(DeliveredNotification(title: request.content.title, body: request.content.body))
                    }
                    completion(nil)
                }
            )
        }
    }

    private struct LostConnection: LocalizedError {
        var errorDescription: String? { "The peer went away" }
    }

    /// Runs `body` on a service that delivers to `notificationCenter` and reads `settings`.
    private func withService(
        notificationCenter: RecordingNotificationCenter,
        settings: SettingsAccess,
        _ body: (RuntimeConnectionNotificationService) -> Void
    ) {
        withDependencies {
            $0.userNotificationCenterClient = notificationCenter.client
            $0.settings = settings
        } operation: {
            body(RuntimeConnectionNotificationService())
        }
    }

    @Test("Connecting to an engine is announced while notifications and connect notifications are on")
    func connectionIsAnnounced() {
        let notificationCenter = RecordingNotificationCenter()

        withService(notificationCenter: notificationCenter, settings: .preview) { service in
            service.notifyConnected(source: .local)
        }

        #expect(notificationCenter.deliveredNotifications.value == [
            DeliveredNotification(title: "Connected", body: "Successfully connected to Local Runtime"),
        ])
    }

    @Test("Connecting is not announced once connect notifications are off")
    func connectionIsQuietWhenTurnedOff() {
        let notificationCenter = RecordingNotificationCenter()
        let settings = SettingsAccess.preview
        settings.notifications.showOnConnect = false

        withService(notificationCenter: notificationCenter, settings: settings) { service in
            service.notifyConnected(source: .local)
        }

        #expect(notificationCenter.deliveredNotifications.value.isEmpty)
    }

    @Test("A lost connection says what went wrong")
    func lostConnectionSaysWhy() {
        let notificationCenter = RecordingNotificationCenter()

        withService(notificationCenter: notificationCenter, settings: .preview) { service in
            service.notifyDisconnected(source: .local, error: LostConnection())
        }

        #expect(notificationCenter.deliveredNotifications.value == [
            DeliveredNotification(title: "Disconnected", body: "Lost connection to Local Runtime: The peer went away"),
        ])
    }

    @Test("A restart of the local runtime is announced even with connect and disconnect notifications off")
    func localRestartIgnoresTheConnectionToggles() {
        let notificationCenter = RecordingNotificationCenter()
        let settings = SettingsAccess.preview
        settings.notifications.showOnConnect = false
        settings.notifications.showOnDisconnect = false

        withService(notificationCenter: notificationCenter, settings: settings) { service in
            service.notifyLocalRuntimeRestarted()
        }

        #expect(notificationCenter.deliveredNotifications.value.map(\.title) == ["Local Runtime Restarted"])
    }

    @Test("Nothing is announced while notifications are off")
    func nothingWhileNotificationsAreOff() {
        let notificationCenter = RecordingNotificationCenter()
        let settings = SettingsAccess.preview
        settings.notifications.isEnabled = false

        withService(notificationCenter: notificationCenter, settings: settings) { service in
            service.notifyConnected(source: .local)
            service.notifyDisconnected(source: .local, error: nil)
            service.notifyCatalystHelperUnavailable(error: LostConnection())
            service.notifyLocalRuntimeRestarted()
        }

        #expect(notificationCenter.deliveredNotifications.value.isEmpty)
    }
}
