//
//  EventMonitor.swift
//  XMLViewer
//
//  Created by JH on 2024/3/21.
//

import AppKit

class EventMonitor {
    private var monitors: [Any?] = []

    func addGlobalMonitorForEvents(matching mask: NSEvent.EventTypeMask, handler block: @escaping (NSEvent) -> Void) {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask, handler: block))
    }

    func addLocalMonitorForEvents(matching mask: NSEvent.EventTypeMask, handler block: @escaping (NSEvent) -> NSEvent?) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask, handler: block))
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor(_:))
    }
}
