#import <AppKit/AppKit.h>
#import <UXKit/UXBar.h>
#import <UXKit/UXBarButtonItem.h>
#import <UXKit/UXKitDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class UXToolbar;
NS_SWIFT_UI_ACTOR
@protocol UXToolbarDelegate <UXBarPositioningDelegate>

@optional
- (nullable NSResponder *)nextResponderForToolbar:(UXToolbar *)toolbar;

@end

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXToolbar : UXBar

@property (nonatomic, copy, nullable) NSArray<UXBarButtonItem *> *items;
@property (nonatomic, weak, nullable) id <UXToolbarDelegate> delegate;

- (void)setItems:(nullable NSArray<UXBarButtonItem *> *)items animated:(BOOL)animated;

@end


NS_HEADER_AUDIT_END(nullability, sendability)
