//
//  main.swift
//  ProbeService
//
//  Stands in for the Catalyst helper. This executable is tagged Mac Catalyst
//  and that is all it is for: it makes the process a Catalyst one. The work is
//  done by a macOS plugin bundle it loads — the arrangement the real helper
//  uses — and that plugin parks the main thread in xpc_main.
//

import Foundation
import XPC

if let pluginPath = Bundle.main.builtInPlugInsURL?.appendingPathComponent("ProbePlugin.bundle").path,
   let pluginBundle = Bundle(path: pluginPath),
   let principalClass = pluginBundle.principalClass as? NSObject.Type {
    // Does not return.
    principalClass.init().perform(NSSelectorFromString("runService"))
}

// The plugin did not load. Serve anyway, so the host can tell this apart
// from a service that never launched.
xpc_main { peerConnection in
    xpc_connection_set_event_handler(peerConnection) { event in
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(event) else { return }
        xpc_dictionary_set_string(reply, "failure", "could not load ProbePlugin.bundle from \(Bundle.main.builtInPlugInsPath ?? "nil")")
        xpc_connection_send_message(peerConnection, reply)
    }
    xpc_connection_resume(peerConnection)
}
