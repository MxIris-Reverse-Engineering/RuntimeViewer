//
//  main.swift
//  ProbeHost
//
//  Stands in for RuntimeViewer.app: a plain macOS process that asks its
//  embedded Mac Catalyst XPC service for a report and prints it next to its
//  own platform, so the two can be compared.
//

import Foundation
import XPC

func writeLine(_ text: String) {
    FileHandle.standardOutput.write(Data((text + "\n").utf8))
}

func activePlatform() -> UInt32? {
    // dyld SPI. RTLD_DEFAULT is ((void *)-2) and does not import into Swift.
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_get_active_platform") else { return nil }
    typealias ActivePlatformFunction = @convention(c) () -> UInt32
    return unsafeBitCast(symbol, to: ActivePlatformFunction.self)()
}

// A service that never comes up must not leave the probe hanging.
DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
    writeLine("result: timed out waiting for the service")
    exit(2)
}

let serviceName = Bundle.main.object(forInfoDictionaryKey: "ProbeServiceName") as? String ?? ""
writeLine("host activePlatform: \(activePlatform().map { String($0) } ?? "unknown") (1 = macOS, 6 = Mac Catalyst)")
writeLine("host isMacCatalystApp: \(ProcessInfo.processInfo.isMacCatalystApp)")
writeLine("connecting to: \(serviceName)")

let connectionStart = Date()
let connection = xpc_connection_create(serviceName, nil)
// Connection errors also come back as the reply below, which is where they are reported.
xpc_connection_set_event_handler(connection) { _ in }
xpc_connection_resume(connection)

let reply = xpc_connection_send_message_with_reply_sync(connection, xpc_dictionary_create(nil, nil, 0))
let elapsedMilliseconds = Int(Date().timeIntervalSince(connectionStart) * 1000)

guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
    let description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION).map { String(cString: $0) } ?? "unknown error"
    writeLine("result: no reply after \(elapsedMilliseconds) ms — \(description)")
    exit(1)
}
writeLine("first reply after: \(elapsedMilliseconds) ms (includes the service's cold launch)")
writeLine("service processIdentifier: \(xpc_connection_get_pid(connection))")

if let failure = xpc_dictionary_get_string(reply, "failure") {
    writeLine("result: the service launched but its plugin did not load — \(String(cString: failure))")
    exit(1)
}
writeLine(xpc_dictionary_get_string(reply, "report").map { String(cString: $0) } ?? "result: the reply carried no report")
exit(0)
