@_exported import SnapKit
@_exported import SFSymbols
@_exported import UIFoundation
@_exported import UIFoundationToolbox

// AppKitPlus is deliberately NOT `@_exported`. Its `NSKeyConstants.h` pulls in
// `<Carbon/Carbon.h>`, and the framework's module map re-exports everything it
// imports, so re-exporting AppKitPlus would put Carbon's bare-word types
// (`Control`, `Point`, `Style`, …) into every file that imports RuntimeViewerUI —
// `AreaSegmentedControl: Control` stops resolving the moment it happens. Import
// AppKitPlus explicitly in the handful of files that need the navigation stack.
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
@_exported import RunningApplicationKit
@_exported import Rearrange
@_exported import SystemHUD
#endif

