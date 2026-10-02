//
//  RuntimeViewerProcessEnumerationSupport.h
//
//  The `libproc` surface the process enumerator needs, declared for the
//  platforms whose SDK withholds the header.
//
//  On macOS `<libproc.h>` is included as-is. The iOS SDK does not ship it at
//  all — unlike `<mach/mach_vm.h>`, which it ships containing nothing but an
//  `#error`, so no `__has_include` trap here; the file is simply absent. Every
//  routine below is exported from the public `usr/lib/libSystem.B.tbd` and
//  links against the stock iPhoneOS SDK, and the macOS header's own
//  availability annotations read `__IPHONE_2_0` / `__IPHONE_4_1` — Apple
//  documents them as iOS API and declines to publish the declarations.
//
//  `<sys/proc_info.h>` is absent too, which is why nothing here reaches for
//  `proc_pidinfo` and `struct proc_bsdinfo`: using them would mean copying a
//  kernel struct layout by hand. `<sys/sysctl.h>` *does* ship on iOS and
//  carries `struct kinfo_proc`, so the owning uid comes from `sysctl` instead —
//  no copied ABI, at the cost of one call per process.
//

#ifndef RuntimeViewerProcessEnumerationSupport_h
#define RuntimeViewerProcessEnumerationSupport_h

#include <TargetConditionals.h>
#include <sys/types.h>
#include <stdint.h>

#if TARGET_OS_OSX || TARGET_OS_MACCATALYST

#include <libproc.h>

#else

__BEGIN_DECLS

/// Fills `buffer` with every pid the caller is allowed to see, and returns the
/// number of **bytes** written. Called with a `NULL` buffer and size `0` it
/// instead returns a capacity hint, which is an upper bound and not the exact
/// count — allocate from the hint, then size the result from the return value.
///
/// Returns `-1` with `errno == EPERM` for a containerized caller, whatever
/// task-port entitlements it holds. A sandbox escape is the prerequisite.
extern int proc_listallpids(void *buffer, int buffersize);

/// The process's short name (its `p_comm`), truncated by the kernel.
extern int proc_name(int pid, void *buffer, uint32_t buffersize);

/// The process's executable path.
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

__END_DECLS

/// From `<sys/proc_info.h>`, which the iOS SDK does not ship. Spelled out
/// because it is a macro there and macros do not reach Swift.
#define PROC_PIDPATHINFO_MAXSIZE (4 * 1024)

#endif /* TARGET_OS_OSX || TARGET_OS_MACCATALYST */

/// `PROC_PIDPATHINFO_MAXSIZE` as something Swift can see.
///
/// On macOS it comes from a macro in `<sys/proc_info.h>`, and on iOS from the
/// one defined above; either way a macro is invisible to Swift, so it is
/// re-exported as a constant. The two must agree, which they do by
/// construction — the iOS definition is copied from the macOS header.
static const uint32_t RuntimeViewerProcessPathMaximumLength = PROC_PIDPATHINFO_MAXSIZE;

/// How large a buffer `proc_name` is given. The kernel truncates to `p_comm`'s
/// width, far below this; the slack costs one stack buffer per process and
/// removes a reason to care what that width is on any given release.
static const uint32_t RuntimeViewerProcessNameMaximumLength = 256;

#endif /* RuntimeViewerProcessEnumerationSupport_h */
