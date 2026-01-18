import SwiftUI
import Observation

@Observable
final class SettingsViewModel {
    var backButtonVisible: Bool = false
    var scrolledToTop: Bool = false

    /// Holds a monitor closure for the `keyDown` event
    private var keyDownEventMonitor: Any?

    func setKeyDownMonitor(monitor: @escaping (NSEvent) -> NSEvent?) {
        keyDownEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: monitor)
    }

    func removeKeyDownMonitor() {
        if let eventMonitor = keyDownEventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            keyDownEventMonitor = nil
        }
    }

    deinit {
        removeKeyDownMonitor()
    }
}
