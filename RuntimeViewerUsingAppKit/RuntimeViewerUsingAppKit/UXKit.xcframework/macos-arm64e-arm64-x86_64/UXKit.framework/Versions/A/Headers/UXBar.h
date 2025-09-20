#import <AppKit/AppKit.h>
#import <UXKit/UXBarCommon.h>
#import <UXKit/UXKitDefines.h>
#import <UXKit/UXView.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXBar : UXView <NSAccessibilityGroup, UXBarPositioning>
@end

NS_HEADER_AUDIT_END(nullability, sendability)
