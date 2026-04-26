import Foundation
import Darwin
public import FoundationToolbox
import Network
#if canImport(UIKit)
import UIKit
#endif
#if canImport(WatchKit)
import WatchKit
#endif
#if os(macOS)
import SystemConfiguration
#endif

public enum RuntimeNetworkError: Error {
    case notConnected
    case invalidPort
    case receiveFailed
}

public struct RuntimeNetworkRequestError: Error, Codable {
    public let message: String
}

struct RuntimeRequestData: Codable {
    let identifier: String

    let data: Data

    init(identifier: String, data: Data) {
        self.identifier = identifier
        self.data = data
    }

    init<Value: Codable>(identifier: String, value: Value) throws {
        self.identifier = identifier
        self.data = try JSONEncoder().encode(value)
    }

    init<Request: RuntimeRequest>(request: Request) throws {
        self.identifier = Request.identifier
        self.data = try JSONEncoder().encode(request)
    }
}

public enum RuntimeNetworkBonjour {
    public static let type = "_runtimeviewer._tcp"
    public static let instanceIDKey = "rv-instance-id"
    public static let hostNameKey = "rv-host-name"
    public static let modelIDKey = "rv-model-id"
    public static let osVersionKey = "rv-os-ver"
    public static let isSimulatorKey = "rv-sim"

    /// Persistent unique identifier for this app installation, used for self-discovery filtering
    /// and cycle detection in engine mirroring. Persisted in UserDefaults so it survives app restarts.
    public static let localInstanceID: String = {
        let key = "RuntimeViewer.localInstanceID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }()

    /// Reads the kernel hostname via POSIX `gethostname(2)`.
    ///
    /// `ProcessInfo.processInfo.hostName` and `Host.current().name` go through
    /// `-[NSHost name]`, which performs a *blocking* reverse-DNS lookup. On a
    /// fresh iOS install with a cold mDNS cache that lookup can stall the
    /// caller for tens of seconds — long enough to trip FrontBoard's
    /// scene-create watchdog (`0x8BADF00D`). `gethostname(2)` reads the value
    /// directly from the kernel and never touches the network.
    private static func systemHostName() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count) == 0 else {
            return ""
        }
        return String(cString: buffer)
    }

    /// Synchronous, non-blocking local host name.
    ///
    /// Safe to read from any thread — it never touches the network — but the
    /// value can be a generic fallback like `"iPhone"` on iOS devices because
    /// the only non-blocking sources (`gethostname(2)`, `UIDevice.current.name`
    /// without the `user-assigned-device-name` entitlement) don't expose the
    /// user's device name.
    ///
    /// Use this only where blocking is unacceptable (e.g. as the default
    /// `RuntimeEngine.hostInfo`). For Bonjour TXT records and service names
    /// that other devices will see, prefer ``resolvedHostName()``.
    public static let localHostName: String = {
        #if os(macOS)
        return (SCDynamicStoreCopyComputerName(nil, nil) as? String)
            ?? systemHostName()
        #else
        #if !targetEnvironment(simulator)
        let hostName = systemHostName()
            .replacingOccurrences(of: ".local", with: "")
        if !hostName.isEmpty && hostName != "localhost" {
            return hostName
        }
        #endif
        #if os(watchOS)
        return WKInterfaceDevice.current().name
        #elseif canImport(UIKit)
        return UIDevice.current.name
        #else
        return systemHostName()
        #endif
        #endif
    }()

    /// User-friendly local host name, resolved off the calling thread.
    ///
    /// On iOS devices `ProcessInfo.processInfo.hostName` reaches the
    /// user-assigned name (e.g. `"JHs-iPhone"`) by performing a *blocking*
    /// reverse-DNS lookup against mDNSResponder. We hop onto a detached
    /// background task so the calling thread (often the main thread during
    /// scene-create) is never blocked even when the mDNS cache is cold —
    /// that scenario was the cause of the `0x8BADF00D` watchdog crash on
    /// first launch.
    ///
    /// The mDNSResponder cache means the second call is essentially free.
    public static func resolvedHostName() async -> String {
        await Task.detached(priority: .utility) {
            #if os(macOS)
            if let name = SCDynamicStoreCopyComputerName(nil, nil) as? String,
               !name.isEmpty {
                return name
            }
            #elseif !targetEnvironment(simulator) && !os(watchOS)
            let mdnsName = ProcessInfo.processInfo.hostName
                .replacingOccurrences(of: ".local", with: "")
            if !mdnsName.isEmpty && mdnsName != "localhost" {
                return mdnsName
            }
            #endif
            return localHostName
        }.value
    }

    static func makeService(name: String) async -> NWListener.Service {
        var txtRecord = NWTXTRecord()
        txtRecord[instanceIDKey] = localInstanceID
        txtRecord[hostNameKey] = await resolvedHostName()
        txtRecord[modelIDKey] = DeviceMetadata.current.modelIdentifier
        txtRecord[osVersionKey] = DeviceMetadata.current.osVersion
        if DeviceMetadata.current.isSimulator {
            txtRecord[isSimulatorKey] = "1"
        }
        return NWListener.Service(name: name, type: type, txtRecord: txtRecord)
    }

    static func instanceID(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let txtRecord) = metadata else { return nil }
        return txtRecord[instanceIDKey]
    }

    static func hostName(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let record) = metadata else { return nil }
        return record[hostNameKey]
    }

    static func deviceMetadata(from metadata: NWBrowser.Result.Metadata) -> DeviceMetadata? {
        guard case .bonjour(let record) = metadata else { return nil }
        guard let modelID = record[modelIDKey],
              let osVersion = record[osVersionKey] else { return nil }
        let isSimulator = record[isSimulatorKey] == "1"
        return DeviceMetadata(modelIdentifier: modelID, osVersion: osVersion, isSimulator: isSimulator)
    }
}

public struct RuntimeNetworkEndpoint: Sendable, Hashable {
    public let name: String
    public let instanceID: String?
    public let hostName: String?
    public let deviceMetadata: DeviceMetadata?

    let endpoint: NWEndpoint

    init(name: String, instanceID: String? = nil, hostName: String? = nil, deviceMetadata: DeviceMetadata? = nil, endpoint: NWEndpoint) {
        self.name = name
        self.instanceID = instanceID
        self.hostName = hostName
        self.deviceMetadata = deviceMetadata
        self.endpoint = endpoint
    }

    // Exclude instanceID and hostName from equality — they are metadata, not identity.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.name == rhs.name && lhs.endpoint == rhs.endpoint
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(endpoint)
    }
}

@Loggable
public class RuntimeNetworkBrowser {
    private let browser: NWBrowser

    public init() {
        let parameters = NWParameters()
        parameters.includePeerToPeer = true

        self.browser = NWBrowser(for: .bonjourWithTXTRecord(type: RuntimeNetworkBonjour.type, domain: nil), using: parameters)
    }

    public func start(
        onAdded: @escaping (RuntimeNetworkEndpoint) -> Void,
        onRemoved: @escaping (RuntimeNetworkEndpoint) -> Void
    ) {
        #log(.info, "Starting Bonjour browser for service type: \(RuntimeNetworkBonjour.type, privacy: .public)")
        browser.stateUpdateHandler = { newState in
            #log(.info, "Browser state changed: \(String(describing: newState), privacy: .public)")
        }
        browser.browseResultsChangedHandler = { results, changes in
            #log(.info, "Browse results changed: \(results.count, privacy: .public) result(s), \(changes.count, privacy: .public) change(s)")
            for change in changes {
                switch change {
                case .added(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let instanceID = RuntimeNetworkBonjour.instanceID(from: result.metadata)
                        let hostName = RuntimeNetworkBonjour.hostName(from: result.metadata)
                        let deviceMetadata = RuntimeNetworkBonjour.deviceMetadata(from: result.metadata)
                        #log(.info, "Discovered new endpoint: \(name, privacy: .public), instanceID: \(instanceID ?? "nil", privacy: .public), hostName: \(hostName ?? "nil", privacy: .public)")
                        onAdded(.init(name: name, instanceID: instanceID, hostName: hostName, deviceMetadata: deviceMetadata, endpoint: result.endpoint))
                    }
                case .removed(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let instanceID = RuntimeNetworkBonjour.instanceID(from: result.metadata)
                        let hostName = RuntimeNetworkBonjour.hostName(from: result.metadata)
                        let deviceMetadata = RuntimeNetworkBonjour.deviceMetadata(from: result.metadata)
                        #log(.info, "Endpoint removed: \(name, privacy: .public)")
                        onRemoved(.init(name: name, instanceID: instanceID, hostName: hostName, deviceMetadata: deviceMetadata, endpoint: result.endpoint))
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}
