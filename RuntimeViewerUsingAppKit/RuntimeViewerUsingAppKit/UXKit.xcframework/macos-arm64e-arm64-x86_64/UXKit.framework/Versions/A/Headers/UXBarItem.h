#import <AppKit/AppKit.h>
#import <UXKit/UXKitDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class NSImage, NSString;

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXBarItem : NSObject

@property (nonatomic) NSInteger tag;
@property (nonatomic, getter = isEnabled) BOOL enabled;
@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, strong, nullable) NSString *title;
@property (nonatomic, copy, nullable) NSString *accessibilityLabel;
@property (nonatomic, copy, nullable) NSString *accessibilityIdentifier;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

@end



NS_HEADER_AUDIT_END(nullability, sendability)
