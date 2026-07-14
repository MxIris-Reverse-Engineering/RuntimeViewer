//
//  RuntimeViewerObjC.m
//  Core
//
//  Created by JH on 11/12/25.
//

#import "RuntimeViewerCoreObjC.h"
#include <stdint.h>

const void * _Nullable RVClassFromString(NSString *className) {
    return (__bridge void * _Nullable)(NSClassFromString(className));
}

const void * _Nullable RVProtocolFromString(NSString *protocolName) {
    return (__bridge void * _Nullable)(NSProtocolFromString(protocolName));
}

// `sandbox_check` is SPI (declared in the private <sandbox.h>). Declare the
// prototype locally rather than importing the private header.
extern int sandbox_check(pid_t pid, const char *operation, uint32_t type, ...);

// Values from the private sandbox headers.
#define RVSandboxFilterGlobalName 2u
#define RVSandboxCheckNoReport 0x40000000u

int RVSandboxCheckGlobalName(pid_t pid, const char *operation, const char *globalName) {
    // NO_REPORT suppresses the sandbox-violation log a plain probe would emit.
    return sandbox_check(pid, operation, RVSandboxFilterGlobalName | RVSandboxCheckNoReport, globalName);
}
