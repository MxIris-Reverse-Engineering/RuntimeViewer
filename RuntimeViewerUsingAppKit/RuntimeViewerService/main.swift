import RuntimeViewerCommunication
import RuntimeViewerService

#if RUNTIMEVIEWER_ARM64E
runtimeViewerIsARM64EVariant = true
#endif

try await RuntimeViewerService.run()
