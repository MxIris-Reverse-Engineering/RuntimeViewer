//
//  main.swift
//  RuntimeViewerLocalService
//
//  The process "My Mac" runs in. The app never dlopens or indexes an image
//  itself: its `.local` engine forwards every request here, and a crash in
//  here costs the loaded images, not the app. launchd starts this service on
//  the app's first message and relaunches it on the next one after it exits,
//  so there is nothing to supervise from this side.
//
//  The executable is only a shell. The work is done by
//  RuntimeViewerServicePlugin, which all four shells load, so the app ships
//  one copy of RuntimeViewerCore for them instead of one per executable.
//

import Foundation

do {
    // Does not return: the plugin ends up in `xpc_main`.
    try ServicePluginLoader.loadPlugin().runLocalService()
} catch {
    // Without the plugin there is no service; let launchd see a clean failure.
    FileHandle.standardError.write(Data("RuntimeViewerLocalService: could not load the plugin at \(ServicePluginLoader.pluginBundleURL.path): \(error)\n".utf8))
}
exit(EXIT_FAILURE)
