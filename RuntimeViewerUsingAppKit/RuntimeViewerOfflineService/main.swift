//
//  main.swift
//  RuntimeViewerOfflineService
//
//  The process an offline file is read in. The service declares
//  `_MultipleInstances`, and the app starts an instance of it for every file
//  it opens: the connection's first hello names the file, and
//  `RuntimeOfflineServiceHost` reads it and serves it before answering. One
//  instance serves one file to one client, for good — when that client goes
//  away, so does the process, and the parsed file with it.
//
//  This service links neither RuntimeViewerInjection nor
//  RuntimeViewerCrossReferences, so it has no `install()` to call: a file has
//  no processes to inject into, and the cross-reference scan reads images
//  mapped into the serving process, which a file's images never are. The app
//  does not ask an offline engine for either.
//

import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

let listener: RuntimeXPCServiceListenerConnection
do {
    listener = try RuntimeXPCServiceListenerConnection.embeddedService()
} catch {
    // Without a listener there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerOfflineService: could not create the service listener: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}

// Derived data — the Find corpora of the cache images this instance reads —
// kept under the identity of the dyld shared cache they come from, not this
// Mac's; see `RuntimeDerivedData.offlineStore(for:isSharedCacheImage:)`.
RuntimeDerivedData.enableForOfflineEngineInThisProcess()

let host = RuntimeOfflineServiceHost(connection: listener)

// Nobody else can ever reach this instance — launchd starts a new one for
// every connection — so once its client closed the connection, exiting is the
// only way the parsed file's memory is given back.
listener.setClientDepartureHandler {
    exit(EXIT_SUCCESS)
}

// `xpc_main`; never returns. Nothing is read until the first hello names the
// file, so there is nothing to set up first.
host.activate()
