//
//  LegacyHelperTool.h
//  RuntimeViewerPackages
//
//  Created by JH on 2026/1/17.
//

#import <TargetConditionals.h>

#if TARGET_OS_OSX

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

NS_SWIFT_NAME(LegacyHelperTool)
@interface RVLegacyHelperTool : NSObject

/**
 * Installs the helper tool using the legacy SMJobBless API.
 * This is primarily used for supporting macOS versions prior to 13.0 or legacy setups.
 *
 * @param serviceName The Mach service name (Label) of the helper tool.
 * @param error If the installation fails, this pointer is set to an NSError object.
 * @return YES if successful, NO otherwise.
 */
+ (BOOL)installWithServiceName:(NSString *)serviceName error:(NSError **)error;

/**
 * Uninstalls the helper tool using the legacy SMJobRemove API.
 *
 * @note IMPORTANT: Even though SMJobRemove is deprecated, it is the ONLY official way
 * to properly remove a helper tool installed via SMJobBless.
 * Use this to clean up old versions before migrating to SMAppService.
 *
 * @param serviceName The Mach service name (Label) of the helper tool.
 * @param error If the removal fails, this pointer is set to an NSError object.
 * @return YES if successful, NO otherwise.
 */
+ (BOOL)uninstallWithServiceName:(NSString *)serviceName error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END

#endif
