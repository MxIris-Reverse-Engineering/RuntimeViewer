import RuntimeViewerService

#if RUNTIMEVIEWER_ARM64E
import RuntimeViewerCommunication
runtimeViewerIsARM64EVariant = true
#endif

try await RuntimeViewerService.run()
