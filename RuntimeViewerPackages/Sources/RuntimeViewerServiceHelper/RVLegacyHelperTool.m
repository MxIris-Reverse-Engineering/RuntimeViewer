//
//  LegacyHelperTool.m
//  RuntimeViewerPackages
//
//  Created by JH on 2026/1/17.
//

#if TARGET_OS_OSX

#import "RVLegacyHelperTool.h"
#import <ServiceManagement/ServiceManagement.h>
#import <Security/Security.h>

@implementation RVLegacyHelperTool

#pragma mark - Public API

+ (BOOL)installWithServiceName:(NSString *)serviceName error:(NSError **)error {
    // kSMRightBlessPrivilegedHelper is the standard right string for installing helpers
    AuthorizationRef authRef = [self createAuthorizationRefForRight:kSMRightBlessPrivilegedHelper error:error];
    
    if (!authRef) {
        return NO;
    }
    
    CFErrorRef cfError = NULL;
    BOOL result = NO;

    /* START IGNORE DEPRECATION
     Reason: SMJobBless is deprecated in macOS 10.10 in favor of SMAppService (macOS 13+).
     However, we wrap this in Objective-C to isolate the legacy logic required for
     older OS support or specific legacy install scenarios.
    */
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    result = (BOOL)SMJobBless(kSMDomainSystemLaunchd,
                              (__bridge CFStringRef)serviceName,
                              authRef,
                              &cfError);
    
    #pragma clang diagnostic pop
    /* END IGNORE DEPRECATION */

    // Cleanup authorization reference
    AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
    
    if (!result && cfError) {
        if (error) {
            *error = (__bridge_transfer NSError *)cfError;
        } else {
            CFRelease(cfError);
        }
        return NO;
    }
    
    return result;
}

+ (BOOL)uninstallWithServiceName:(NSString *)serviceName error:(NSError **)error {
    // kSMRightModifySystemDaemons is required to remove jobs from Launchd
    AuthorizationRef authRef = [self createAuthorizationRefForRight:kSMRightModifySystemDaemons error:error];
    
    if (!authRef) {
        return NO;
    }
    
    CFErrorRef cfError = NULL;
    BOOL result = NO;

    /* START IGNORE DEPRECATION
     Reason: SMJobRemove is deprecated, but Apple has not provided a replacement API
     in the ServiceManagement framework for removing tools installed via SMJobBless.
     We must use this API to clean up legacy helpers to prevent conflicts when
     migrating to SMAppService.
    */
    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Wdeprecated-declarations"
    
    result = (BOOL)SMJobRemove(kSMDomainSystemLaunchd,
                               (__bridge CFStringRef)serviceName,
                               authRef,
                               true, // Wait for the process to exit
                               &cfError);
    
    #pragma clang diagnostic pop
    /* END IGNORE DEPRECATION */

    // Cleanup authorization reference
    AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);

    if (!result) {
        if (cfError) {
            if (error) {
                *error = (__bridge_transfer NSError *)cfError;
            } else {
                CFRelease(cfError);
            }
        }
        return NO;
    }
    
    return YES;
}

#pragma mark - Private Helper

+ (AuthorizationRef)createAuthorizationRefForRight:(const char *)rightName error:(NSError **)error {
    OSStatus status;
    AuthorizationRef authRef = NULL;
    
    // 1. Define the item (the right we want to request)
    AuthorizationItem authItem = { rightName, 0, NULL, 0 };
    
    // 2. Wrap it in a rights set
    AuthorizationRights authRights = { 1, &authItem };
    
    // 3. Define flags: Allow UI interaction, extend rights, and pre-authorize
    AuthorizationFlags flags = kAuthorizationFlagInteractionAllowed |
                               kAuthorizationFlagExtendRights |
                               kAuthorizationFlagPreAuthorize;
    
    // 4. Request the authorization
    status = AuthorizationCreate(&authRights, kAuthorizationEmptyEnvironment, flags, &authRef);
    
    if (status != errAuthorizationSuccess) {
        if (error) {
            NSString *errorMessage = (__bridge_transfer NSString *)SecCopyErrorMessageString(status, NULL);
            *error = [NSError errorWithDomain:NSOSStatusErrorDomain
                                         code:status
                                     userInfo:@{NSLocalizedDescriptionKey: errorMessage ?: @"Authorization Failed"}];
        }
        return NULL;
    }
    
    return authRef;
}

@end

#endif
