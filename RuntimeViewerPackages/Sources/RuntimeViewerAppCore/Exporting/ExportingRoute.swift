#if os(macOS)

import RuntimeViewerArchitectures

public enum ExportingRoute: Routable {
    case initial
    case previous
    case next
    case cancel
    case directoryPicker
}

#endif
