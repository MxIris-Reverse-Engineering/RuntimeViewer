import AppKit
import RuntimeViewerUI

/// Window controller hosting the modal specialization sheet. Mirrors the
/// `ExportingWindowController` pattern: a thin `XiblessWindowController`
/// shell whose `contentViewController` is assigned by the coordinator.
final class SpecializationWindowController: XiblessWindowController<NSWindow> {}
