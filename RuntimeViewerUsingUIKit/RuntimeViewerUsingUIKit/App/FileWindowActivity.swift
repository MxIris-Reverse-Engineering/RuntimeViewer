import Foundation

/// The user activity a window opened for a file is requested with: it carries
/// the identifier under which `DocumentSessionRegistry` holds the file's
/// engine, and the new window hands it back as it connects.
///
/// Its type is `<bundle identifier>.fileWindow`, which each app's
/// `Info.plist` lists under `NSUserActivityTypes`.
enum FileWindowActivity {
    private static let requestIdentifierKey = "requestIdentifier"

    static var activityType: String {
        (Bundle.main.bundleIdentifier ?? "RuntimeViewer") + ".fileWindow"
    }

    /// An activity naming `requestIdentifier`.
    static func make(requestIdentifier: UUID) -> NSUserActivity {
        let activity = NSUserActivity(activityType: activityType)
        activity.userInfo = [requestIdentifierKey: requestIdentifier.uuidString]
        return activity
    }

    /// The request `activity` names, when it is a file window's.
    static func requestIdentifier(of activity: NSUserActivity) -> UUID? {
        guard activity.activityType == activityType,
              let string = activity.userInfo?[requestIdentifierKey] as? String else { return nil }
        return UUID(uuidString: string)
    }
}
