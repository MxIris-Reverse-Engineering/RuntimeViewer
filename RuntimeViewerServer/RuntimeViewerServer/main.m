#include <stddef.h>

extern void swift_initializeRuntimeViewerServer(void);

__attribute__((constructor, used))
static void initializeRuntimeViewerServer(void) {
    swift_initializeRuntimeViewerServer();
}

// Exported entry for mach_vm_remap-based injection paths (see
// MachInjectorRemap). Those paths hand the framework image straight to the
// target's VM space rather than going through dlopen, so dyld's constructor
// invocation never fires. Callers explicitly resolve this symbol and jump to
// it from the injected pthread bootstrap; from there on the initialization
// path is identical to the constructor-driven one above.
//
// The signature matches pthread_create's start_routine (void *(*)(void *))
// so a raw pthread spawned by the mach-thread bootstrap can use it directly.
// The argument slot is currently unused and the return value is nil — the
// pthread just exits after RuntimeViewerServer's Task { } takes over.
__attribute__((visibility("default"), used))
void *runtime_viewer_server_start(void *argument) {
    (void)argument;
    swift_initializeRuntimeViewerServer();
    return NULL;
}
