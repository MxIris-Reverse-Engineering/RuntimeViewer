//
//  main.swift
//  RuntimeViewerCatalystService
//
//  The process "My Mac (Mac Catalyst)" runs in when the app asks for it. This
//  executable is tagged Mac Catalyst and that is all it is for: it makes the
//  process a Catalyst one. The work is done by RuntimeViewerServicePlugin, the
//  macOS plugin all four shells load. launchd starts this service on the
//  app's first message and starts it again on the next one after it exits.
//

import Foundation

do {
    // Does not return: the plugin ends up in `xpc_main`.
    try ServicePluginLoader.loadPlugin().runCatalystService()
} catch {
    // Without the plugin there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerCatalystService: could not load the plugin at \(ServicePluginLoader.pluginBundleURL.path): \(error)\n".utf8))
}
exit(EXIT_FAILURE)
