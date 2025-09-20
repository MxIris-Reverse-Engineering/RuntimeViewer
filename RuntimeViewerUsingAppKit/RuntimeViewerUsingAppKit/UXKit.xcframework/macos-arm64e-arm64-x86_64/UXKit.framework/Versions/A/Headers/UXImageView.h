#import <AppKit/AppKit.h>
#import <UXKit/UXKitDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)


UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXImageView : UXView <NSAccessibilityImage>

@property (nonatomic, getter = isHighlighted) BOOL highlighted;
@property (nonatomic, strong, nullable) NSImage *image;
@property (nonatomic, strong, nullable) NSImage *highlightedImage;

@property (nonatomic) BOOL allowsVibrancy;
@property (nonatomic, copy, nullable) NSString *accessibilityLabel;

- (instancetype)initWithImage:(nullable NSImage *)image highlightedImage:(nullable NSImage *)highlightedImage;
- (instancetype)initWithImage:(nullable NSImage *)image;
- (void)sizeToFit;

@end

NS_HEADER_AUDIT_END(nullability, sendability)
