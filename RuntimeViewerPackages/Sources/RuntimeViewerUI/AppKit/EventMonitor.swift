#if os(macOS)

import AppKit

public final class EventMonitor {
    private var monitors: [Any?] = []

    public init() {}

    public func addGlobalMonitorForEvents(matching mask: NSEvent.EventTypeMask, handler block: @escaping (NSEvent) -> Void) {
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: mask, handler: block))
    }

    public func addLocalMonitorForEvents(matching mask: NSEvent.EventTypeMask, handler block: @escaping (NSEvent) -> NSEvent?) {
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: mask, handler: block))
    }

    deinit {
        monitors.forEach(NSEvent.removeMonitor(_:))
    }
}

#endif
