// A facade with no code of its own: the apps link this one product and import this one module.
// The view models and the application logic are in RuntimeViewerAppCore, the UI glue that drives
// AppKit controls is in RuntimeViewerAppUI (RuntimeViewerPackages/Sources/AGENTS.md).
@_exported import RuntimeViewerAppCore
@_exported import RuntimeViewerAppUI
