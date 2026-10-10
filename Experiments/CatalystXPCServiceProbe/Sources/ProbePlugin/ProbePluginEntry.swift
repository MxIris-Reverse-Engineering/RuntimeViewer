//
//  ProbePluginEntry.swift
//  ProbePlugin
//
//  macOS code running inside the Mac Catalyst service process, as
//  RuntimeViewerCatalystHelperPlugin does inside the helper. Answers every
//  message with a report on what this process sees and can load.
//

import Foundation
import MachO
import XPC

@objc(ProbePluginEntry)
final class ProbePluginEntry: NSObject {
    @objc func runService() {
        xpc_main { peerConnection in
            xpc_connection_set_event_handler(peerConnection) { event in
                guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(event) else { return }
                xpc_dictionary_set_string(reply, "report", ProbeReport.collect())
                xpc_connection_send_message(peerConnection, reply)
            }
            xpc_connection_resume(peerConnection)
        }
    }
}

enum ProbeReport {
    /// The macOS spellings on purpose: in a Catalyst process dyld is expected
    /// to find both under /System/iOSSupport. SwiftUI is one of the frameworks
    /// that ship as two separate binaries, so its path shows which one was taken.
    static let requestedImagePaths = [
        "/System/Library/Frameworks/UIKit.framework/UIKit",
        "/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
    ]

    static func collect() -> String {
        var lines: [String] = []
        func record(_ label: String, _ value: Any?) {
            lines.append("\(label): \(value.map { "\($0)" } ?? "nil")")
        }

        record("service activePlatform", activePlatform())
        record("service isMacCatalystApp", ProcessInfo.processInfo.isMacCatalystApp)
        record("service bundle", Bundle.main.bundlePath)

        let imagesAtStart = loadedImagePaths()
        record("images at start", imagesAtStart.count)
        record("UIKitCore at start", imagesAtStart.first { $0.hasSuffix("/UIKitCore") })
        record("AppKit at start", imagesAtStart.first { $0.hasSuffix("/AppKit") })
        record("classes at start", objc_getClassList(nil, 0))

        for requestedPath in requestedImagePaths {
            let libraryHandle = dlopen(requestedPath, RTLD_NOW)
            let outcome: String? = libraryHandle != nil ? "loaded" : dlerror().map { String(cString: $0) }
            record("dlopen \(requestedPath)", outcome)
        }

        let imagesAfterLoading = loadedImagePaths()
        record("images after loading", imagesAfterLoading.count)
        record("UIKitCore after loading", imagesAfterLoading.first { $0.hasSuffix("/UIKitCore") })
        record("SwiftUI after loading", imagesAfterLoading.first { $0.hasSuffix("/SwiftUI") })
        record("AppKit after loading", imagesAfterLoading.first { $0.hasSuffix("/AppKit") })
        record("classes after loading", objc_getClassList(nil, 0))

        if let viewClass: AnyClass = NSClassFromString("UIView") {
            var methodCount: UInt32 = 0
            free(class_copyMethodList(viewClass, &methodCount))
            record("UIView defined in", class_getImageName(viewClass).map { String(cString: $0) })
            record("UIView instance methods", methodCount)
        } else {
            record("UIView", "class not found")
        }
        return lines.joined(separator: "\n")
    }

    static func activePlatform() -> UInt32? {
        // dyld SPI. RTLD_DEFAULT is ((void *)-2) and does not import into Swift.
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "dyld_get_active_platform") else { return nil }
        typealias ActivePlatformFunction = @convention(c) () -> UInt32
        return unsafeBitCast(symbol, to: ActivePlatformFunction.self)()
    }

    static func loadedImagePaths() -> [String] {
        (0..<_dyld_image_count()).compactMap { imageIndex in
            _dyld_get_image_name(imageIndex).map { String(cString: $0) }
        }
    }
}
