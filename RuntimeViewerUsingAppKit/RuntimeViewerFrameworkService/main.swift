//
//  main.swift
//  RuntimeViewerFrameworkService
//
//  The process Load Frameworks loads frameworks into. The service declares
//  `_MultipleInstances`, and the app starts an instance of it for every Load
//  Frameworks on My Mac, with a window of its own: the frameworks are loaded,
//  and run, here rather than in the local service My Mac runs in, and when no
//  window is left on the instance it goes away and takes them with it.
//
//  The executable is only a shell. The work is done by
//  RuntimeViewerServicePlugin, which all five shells load, so the app ships
//  one copy of RuntimeViewerCore for them instead of one per executable.
//

import Foundation

do {
    // Does not return: the plugin ends up in `xpc_main`.
    try ServicePluginLoader.loadPlugin().runFrameworkService()
} catch {
    // Without the plugin there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerFrameworkService: could not load the plugin at \(ServicePluginLoader.pluginBundleURL.path): \(error)\n".utf8))
}
exit(EXIT_FAILURE)
