//
//  RuntimeViewerObjC.h
//  Core
//
//  Created by JH on 11/12/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT
const void * _Nullable RVClassFromString(NSString *className);

FOUNDATION_EXPORT
const void * _Nullable RVProtocolFromString(NSString *protocolName);

/// Thin wrapper over the SPI `sandbox_check` for a global-name `mach-lookup`.
///
/// Lives in C because `sandbox_check` is variadic: the arm64 variadic ABI passes
/// variadic arguments on the stack, which cannot be expressed through Swift's
/// `@convention(c)` function pointers, so the call must be emitted by the C
/// compiler. Returns `sandbox_check`'s raw result: `0` when the lookup is
/// permitted (or the process is unsandboxed), a positive value when the sandbox
/// denies it, and `-1` on error.
FOUNDATION_EXPORT
int RVSandboxCheckGlobalName(pid_t pid, const char *operation, const char *globalName);

/// Thin wrapper over the SPI `sandbox_check` with a path filter. Used to answer
/// "would `pid`'s sandbox deny `operation` on `path`?" — e.g. whether a target
/// daemon would refuse `file-map-executable` on the RuntimeViewerServer payload,
/// which is what drives the choice between the dlopen and mach_vm_remap
/// injection paths.
///
/// Same variadic-ABI reason as ``RVSandboxCheckGlobalName`` for living in C.
/// Returns 0 when permitted (or unsandboxed), positive when denied, -1 on error.
FOUNDATION_EXPORT
int RVSandboxCheckPath(pid_t pid, const char *operation, const char *path);

NS_ASSUME_NONNULL_END
