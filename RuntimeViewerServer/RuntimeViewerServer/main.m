#include <stdlib.h>

extern void swift_initializeRuntimeViewerServer(void);

// Set by MIMachInjectorRemap around its transient in-injector `dlopen(payload)`,
// which loads the framework into the injector process purely to read its
// mach_header + entry-symbol dladdr result. Skipping the constructor there
// keeps the Swift runtime from spawning `RuntimeViewerServer.main()`'s Task
// in a process that is not the actual injection target — the injector then
// hands the pre-mapped payload off to the real target via mach_vm_remap and
// jumps directly to `runtime_viewer_server_start` there. Regular dlopen-based
// injection into a real target has this env var unset and runs as before.
__attribute__((constructor, used))
static void initializeRuntimeViewerServer(void) {
    if (getenv("RUNTIMEVIEWERSERVER_SKIP_CONSTRUCTOR") != NULL) return;
    swift_initializeRuntimeViewerServer();
}

// -----------------------------------------------------------------------------
// mach_vm_remap injection entry.
// -----------------------------------------------------------------------------
//
// Invoked by MIMachInjectorRemap's stage2 loader after the loader has already
//   * applied every LC_DYLD_CHAINED_FIXUPS slot in the payload against the
//     target's PAC keys (loader_arm64_remap_fixup.c :: apply_fixups), and
//   * replayed dyld's runtime notifications on the target's behalf
//     (loader_arm64_remap_handoff.c :: perform_runtime_handoff) — calling
//     libobjc's `map_images` and libswiftCore's three swift_register* APIs
//     so payload selrefs are uniqued, classes / categories / protocols are
//     registered, and Swift type metadata / protocols / conformances are
//     in libswiftCore's lookup tables.
//
// By the time we reach this function the runtime looks — from the payload's
// perspective — identical to a normal dlopen-loaded image. The only thing
// that never runs is dyld's constructor pass, so we hand-call the Swift
// entry that the constructor above would normally invoke.
//
// `argument` still points at the MIMachInjectorRemapPayloadConfig record
// the injector allocated in the target's address space. Nothing in
// RuntimeViewerServer needs to read it right now — the loader used every
// field on our behalf — but we accept and ignore it so the pthread ABI
// remains `void *(*)(void *)`.
// -----------------------------------------------------------------------------

__attribute__((visibility("default"), used))
void *runtime_viewer_server_start(void *argument) {
    (void)argument;
    swift_initializeRuntimeViewerServer();
    return NULL;
}
