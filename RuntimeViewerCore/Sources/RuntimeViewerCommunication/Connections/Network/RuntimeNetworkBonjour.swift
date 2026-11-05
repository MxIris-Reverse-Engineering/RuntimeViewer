import Foundation
import Network

/// What this project advertises over Bonjour, and how to read it back.
///
/// Only the service type, the TXT record keys and the two directions across
/// them live here. Where the *values* come from is a separate question with a
/// separate set of hazards — see `RuntimeNetworkBonjour+LocalIdentity.swift`.
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
