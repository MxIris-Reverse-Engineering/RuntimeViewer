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
//  The executable is only a shell. The work is done by
//  RuntimeViewerServicePlugin, which all four shells load, so the app ships
//  one copy of RuntimeViewerCore for them instead of one per executable.
//

import Foundation

do {
    // Does not return: the plugin ends up in `xpc_main`.
    try ServicePluginLoader.loadPlugin().runOfflineService()
} catch {
    // Without the plugin there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerOfflineService: could not load the plugin at \(ServicePluginLoader.pluginBundleURL.path): \(error)\n".utf8))
}
exit(EXIT_FAILURE)
