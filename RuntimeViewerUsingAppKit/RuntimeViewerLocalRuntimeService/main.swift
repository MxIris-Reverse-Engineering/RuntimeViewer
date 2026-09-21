//
//  main.swift
//  RuntimeViewerLocalRuntimeService
//
//  The process "My Mac" runs in. The app never dlopens or indexes an image
//  itself any more: its `.local` engine forwards every request here, and a
//  crash in here costs the loaded images, not the app. launchd starts this
//  service on the app's first message and relaunches it on the next one after
//  it exits, so there is nothing to supervise from this side.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

let engine = RuntimeEngine(source: .local, engineID: "local-runtime-service.\(ProcessInfo.processInfo.processIdentifier)")

let host: RuntimeLocalRuntimeServiceHost
do {
    host = RuntimeLocalRuntimeServiceHost(engine: engine, connection: try RuntimeXPCServiceListenerConnection.embeddedService())
} catch {
    // Without a listener there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerLocalRuntimeService: could not create the service listener: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

// Every handler has to be in place before the listener activates — SwiftyXPC
// copies them onto a connection at accept time — and `activate()` is
// `xpc_main`, which parks the main thread for good. So the asynchronous
// set-up runs off the main thread and the main thread waits for it here,
// rather than `await`ing at top level and then calling `xpc_main` from inside
// a block the main queue is still executing.
let setupFinished = DispatchSemaphore(value: 0)
Task.detached {
    do {
        try await host.start()
    } catch {
        FileHandle.standardError.write(Data("RuntimeViewerLocalRuntimeService: could not start the local runtime engine: \(error)\n".utf8))
        exit(EXIT_FAILURE)
    }
    setupFinished.signal()
}
setupFinished.wait()

host.activate()
