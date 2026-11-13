#if os(macOS)
import Foundation
import UserNotifications
import Dependencies
import DependenciesMacros

/// What `RuntimeConnectionNotificationService` asks of the system's notification center.
///
/// A dependency rather than calls on `UNUserNotificationCenter.current()` so that a test sees which
/// notifications the service would deliver from a client of its own: the center needs an application
/// bundle behind the process, which a test runner does not have, and a delivered notification would
/// reach the developer's screen. The default test value records an issue whenever it is asked for anything,
/// so a test that makes the service says which center it expects.
public struct UserNotificationCenterClient: Sendable {
    /// Makes `delegate` the center's delegate.
    public var setDelegate: @MainActor @Sendable (_ delegate: any UNUserNotificationCenterDelegate) -> Void

    /// Asks for permission to show alerts, and calls `completion` with the answer.
    public var requestAuthorization: @Sendable (_ completion: @escaping @Sendable (_ isGranted: Bool, _ error: (any Error)?) -> Void) -> Void

    /// Delivers `request`, and calls `completion` with the error when it could not.
    public var add: @Sendable (_ request: UNNotificationRequest, _ completion: @escaping @Sendable (_ error: (any Error)?) -> Void) -> Void

    public init(
        setDelegate: @escaping @MainActor @Sendable (_ delegate: any UNUserNotificationCenterDelegate) -> Void,
        requestAuthorization: @escaping @Sendable (_ completion: @escaping @Sendable (_ isGranted: Bool, _ error: (any Error)?) -> Void) -> Void,
        add: @escaping @Sendable (_ request: UNNotificationRequest, _ completion: @escaping @Sendable (_ error: (any Error)?) -> Void) -> Void
    ) {
        self.setDelegate = setDelegate
        self.requestAuthorization = requestAuthorization
        self.add = add
    }
}

extension UserNotificationCenterClient {
    /// The process's notification center.
    public static let system = UserNotificationCenterClient(
        setDelegate: { delegate in
            UNUserNotificationCenter.current().delegate = delegate
        },
        requestAuthorization: { completion in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { isGranted, error in
                completion(isGranted, error)
            }
        },
        add: { request, completion in
            UNUserNotificationCenter.current().add(request) { error in
                completion(error)
            }
        }
    )

    /// Records an issue whenever it is asked for anything: a test's default.
    public static let unimplemented = UserNotificationCenterClient(
        setDelegate: { _ in reportIssue("UserNotificationCenterClient.setDelegate is unimplemented") },
        requestAuthorization: { _ in reportIssue("UserNotificationCenterClient.requestAuthorization is unimplemented") },
        add: { _, _ in reportIssue("UserNotificationCenterClient.add is unimplemented") }
    )
}

extension DependencyValues {
    @DependencyEntry(liveValue: UserNotificationCenterClient.system)
    public var userNotificationCenterClient = UserNotificationCenterClient.unimplemented
}
#endif
