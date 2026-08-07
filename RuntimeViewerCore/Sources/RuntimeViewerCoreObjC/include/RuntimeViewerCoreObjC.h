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

NS_ASSUME_NONNULL_END
