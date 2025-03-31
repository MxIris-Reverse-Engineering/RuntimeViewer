#if os(macOS)
import Foundation
import ServiceManagement
import RuntimeViewerCommunication

public enum HelperAuthorizationError: Error {
    case message(String)
}

public enum HelperInstaller {
    private static let daemonService = SMAppService.daemon(plistName: "com.JH.RuntimeViewerService.plist")

    public static func install() throws {
        try daemonService.register()
        print(daemonService.status.rawValue)
    }
}
#endif
