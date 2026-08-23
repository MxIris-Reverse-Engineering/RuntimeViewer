import Foundation
import Darwin
public import FoundationToolbox
import Network
import RuntimeViewerUtilities
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

    /// Per-round-trip routing key. `nil` for fire-and-forget messages and
    /// for messages that originated on a peer that doesn't stamp one
    /// (wire-level backward compat). When non-nil, `sendRequest<Response>`
    /// uses it to key the `pendingRequests` entry — multiple concurrent
    /// in-flight requests can therefore share the same `identifier`
    /// (command name) without colliding on the pending-routing table, so
    /// the channel's `sendSemaphore` no longer has to serialize round
    /// trips end-to-end. Peer-side handlers must echo the value verbatim
    /// in the response envelope; without it the client falls back to
    /// `identifier` (legacy behavior, single in-flight per command).
    let nonce: String?

    /// Marks a response envelope whose `data` carries a
    /// `RuntimeNetworkRequestError` instead of the expected `Response`. Set on
    /// every error reply (the handler threw, or no handler was registered) so
    /// `sendRequest` can surface the remote failure as a real error rather than
    /// an opaque `DecodingError` (or — worse — a bogus all-optional "success").
    /// Optional for wire backward-compat: an absent key decodes to `nil`, which
    /// is treated as "not an error", matching legacy peers that never set it.
    let isError: Bool?

    init(identifier: String, data: Data, nonce: String? = nil, isError: Bool? = nil) {
        self.identifier = identifier
        self.data = data
        self.nonce = nonce
        self.isError = isError
    }

    init<Value: Codable>(identifier: String, value: Value, nonce: String? = nil) throws {
        self.identifier = identifier
        self.data = try JSONEncoder().encode(value)
        self.nonce = nonce
        self.isError = nil
    }

    init<Request: RuntimeRequest>(request: Request, nonce: String? = nil) throws {
        self.identifier = Request.identifier
        self.data = try JSONEncoder().encode(request)
        self.nonce = nonce
        self.isError = nil
    }
}

public enum RuntimeNetworkBonjour {
    public static let type = "_runtimeviewer._tcp"
    public static let instanceIDKey = "rv-instance-id"
    public static let hostNameKey = "rv-host-name"
    public static let modelIDKey = "rv-model-id"
    public static let osVersionKey = "rv-os-ver"
    public static let isSimulatorKey = "rv-sim"

    /// Device-level identifier. Groups every engine advertised from the same
    /// device into one section, which is what makes "one simulator, several
    /// injected processes" render the way local Mac injection already does.
    public static let deviceIDKey = "rv-device-id"

    /// Display name of the advertising *process*, used as the engine entry's
    /// title. The service name cannot carry this: it has to stay globally
    /// unique, and two processes on one device may share a name.
    public static let processNameKey = "rv-proc-name"

    /// Process identifier of the advertising process. Combined with
    /// ``deviceIDKey`` it forms the process-level uniqueness key that the host
    /// uses for deduplication.
    public static let processIdentifierKey = "rv-proc-pid"

    /// Set by an injected payload before it advertises anything.
    ///
    /// An injected payload runs inside a process it does not own, so the
    /// identity it derives must not leave traces there. Today the only such
    /// trace is ``localInstanceID``, whose `UserDefaults.standard` write would
    /// land in the *host* process's preference domain — injecting SpringBoard
    /// would write `RuntimeViewer.localInstanceID` into SpringBoard's plist.
    ///
    /// Must be set before the first read of ``localInstanceID``; the payload's
    /// entry point runs early enough for that.
    nonisolated(unsafe) public static var isRunningInsideInjectedProcess = false

    /// Unique identifier for this app installation, used for self-discovery filtering
    /// and cycle detection in engine mirroring. Persisted in UserDefaults so it survives app restarts.
    ///
    /// Not an identity for *grouping* — see ``localDeviceID`` for that. Two
    /// processes on one device each get their own value, which is exactly what
    /// cycle detection needs and exactly what section grouping must not use.
    public static let localInstanceID: String = {
        let key = "RuntimeViewer.localInstanceID"
        if isRunningInsideInjectedProcess {
            return UUID().uuidString
        }
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let newID = UUID().uuidString
        UserDefaults.standard.set(newID, forKey: key)
        return newID
    }()

    /// Device-level identifier, shared by every process on this device.
    ///
    /// This is what groups engines into one section, so it has to stay stable
    /// across processes — including processes an injected payload does not own.
    /// `SIMULATOR_UDID` comes first for exactly that reason: CoreSimulator puts
    /// it in the environment of every process inside a booted simulator, while
    /// ``DeviceIdentifier/uniqueDeviceID`` falls back to a keychain-backed UUID
    /// when MobileGestalt has no answer — and a keychain lookup made from
    /// inside a foreign process can resolve per-process, which would split one
    /// simulator into a section per injected process.
    public static let localDeviceID: String = {
        #if targetEnvironment(simulator)
        if let simulatorUDID = ProcessInfo.processInfo.environment["SIMULATOR_UDID"], !simulatorUDID.isEmpty {
            return simulatorUDID
        }
        #endif
        return DeviceIdentifier.uniqueDeviceID
    }()

    /// Display name of the advertising process, used as the engine entry's title.
    public static let localProcessName: String = {
        if let displayName = Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String, !displayName.isEmpty {
            return displayName
        }
        if let bundleName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String, !bundleName.isEmpty {
            return bundleName
        }
        return ProcessInfo.processInfo.processName
    }()

    /// Process-level unique service name.
    ///
    /// The Bonjour instance name has to be globally unique — two processes on
    /// one device may well share a display name — so it is built from the
    /// device ID and the pid rather than from anything user-facing. The name a
    /// user sees travels in the TXT record instead (``processNameKey``).
    public static var localServiceName: String {
        "\(localDeviceID)-\(ProcessInfo.processInfo.processIdentifier)"
    }

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
        txtRecord[modelIDKey] = RuntimeDeviceMetadata.current.modelIdentifier
        txtRecord[osVersionKey] = RuntimeDeviceMetadata.current.osVersion
        if RuntimeDeviceMetadata.current.isSimulator {
            txtRecord[isSimulatorKey] = "1"
        }
        txtRecord[deviceIDKey] = localDeviceID
        txtRecord[processNameKey] = localProcessName
        txtRecord[processIdentifierKey] = ProcessInfo.processInfo.processIdentifier.description
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

    static func deviceID(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let record) = metadata else { return nil }
        return record[deviceIDKey]
    }

    static func processName(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let record) = metadata else { return nil }
        return record[processNameKey]
    }

    static func processIdentifier(from metadata: NWBrowser.Result.Metadata) -> String? {
        guard case .bonjour(let record) = metadata else { return nil }
        return record[processIdentifierKey]
    }

    static func deviceMetadata(from metadata: NWBrowser.Result.Metadata) -> RuntimeDeviceMetadata? {
        guard case .bonjour(let record) = metadata else { return nil }
        guard let modelID = record[modelIDKey],
              let osVersion = record[osVersionKey] else { return nil }
        let isSimulator = record[isSimulatorKey] == "1"
        return RuntimeDeviceMetadata(modelIdentifier: modelID, osVersion: osVersion, isSimulator: isSimulator)
    }
}

public struct RuntimeNetworkEndpoint: Sendable, Hashable {
    public let name: String
    public let instanceID: String?
    public let hostName: String?
    public let deviceMetadata: RuntimeDeviceMetadata?

    /// Device-level identifier from the TXT record. Groups every endpoint on
    /// one device into a single section. `nil` for peers predating the key.
    public let deviceID: String?

    /// Display name of the advertising process, from the TXT record.
    /// `nil` for peers predating the key.
    public let processName: String?

    /// Process identifier of the advertising process, from the TXT record.
    /// `nil` for peers predating the key.
    public let processIdentifier: String?

    let endpoint: NWEndpoint

    /// Process-level key used for deduplication and reconnect bookkeeping.
    ///
    /// The service name cannot serve here: an iOS peer advertises one name per
    /// *device*, so a second injected process on the same simulator would be
    /// mistaken for a duplicate of the first and never connect. Peers that
    /// don't publish the new keys fall back to the name, which is what they
    /// have always been keyed by.
    public var uniqueKey: String {
        guard let deviceID, let processIdentifier else { return name }
        return "\(deviceID)-\(processIdentifier)"
    }

    init(
        name: String,
        instanceID: String? = nil,
        hostName: String? = nil,
        deviceMetadata: RuntimeDeviceMetadata? = nil,
        deviceID: String? = nil,
        processName: String? = nil,
        processIdentifier: String? = nil,
        endpoint: NWEndpoint
    ) {
        self.name = name
        self.instanceID = instanceID
        self.hostName = hostName
        self.deviceMetadata = deviceMetadata
        self.deviceID = deviceID
        self.processName = processName
        self.processIdentifier = processIdentifier
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

extension RuntimeNetworkEndpoint {
    /// Builds an endpoint from a browse result, reading every TXT field the
    /// peer published. Keeping this in one place is what stops the `.added` and
    /// `.removed` branches from parsing different subsets — they must agree, or
    /// an endpoint would be keyed one way going in and another coming out.
    init(name: String, result: NWBrowser.Result) {
        self.init(
            name: name,
            instanceID: RuntimeNetworkBonjour.instanceID(from: result.metadata),
            hostName: RuntimeNetworkBonjour.hostName(from: result.metadata),
            deviceMetadata: RuntimeNetworkBonjour.deviceMetadata(from: result.metadata),
            deviceID: RuntimeNetworkBonjour.deviceID(from: result.metadata),
            processName: RuntimeNetworkBonjour.processName(from: result.metadata),
            processIdentifier: RuntimeNetworkBonjour.processIdentifier(from: result.metadata),
            endpoint: result.endpoint
        )
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
                        let discovered = RuntimeNetworkEndpoint(name: name, result: result)
                        #log(.info, "Discovered new endpoint: \(name, privacy: .public), key: \(discovered.uniqueKey, privacy: .public), process: \(discovered.processName ?? "nil", privacy: .public), deviceID: \(discovered.deviceID ?? "nil", privacy: .public), instanceID: \(discovered.instanceID ?? "nil", privacy: .public), hostName: \(discovered.hostName ?? "nil", privacy: .public)")
                        onAdded(discovered)
                    }
                case .removed(let result):
                    if case .service(let name, _, _, _) = result.endpoint {
                        let removed = RuntimeNetworkEndpoint(name: name, result: result)
                        #log(.info, "Endpoint removed: \(name, privacy: .public), key: \(removed.uniqueKey, privacy: .public)")
                        onRemoved(removed)
                    }
                default:
                    break
                }
            }
        }
        browser.start(queue: .main)
    }
}
