#if os(macOS)

import Testing

/// The suites whose managers bring up `RuntimeEngine.local`, run one at a
/// time.
///
/// `.local` is one engine per process, and every manager that lists it hands
/// it shared cache owners — or takes them away — whenever its lists change.
/// Two such suites running side by side would each see the other's owners on
/// it. Nest a suite here, in an extension, when its manager lists `.local`.
@Suite("Managers that bring up RuntimeEngine.local", .serialized)
enum LocalEngineManagerSuites {}

#endif
