#import <AppKit/AppKit.h>
#import <UXKit/UXBar.h>
#import <UXKit/UXNavigationController.h>
#import <UXKit/UXKitDefines.h>

@class UXNavigationItem, _UXNavigationItemContainerView;
NS_SWIFT_UI_ACTOR
@protocol UXNavigationBarDelegate <NSObject>
@end

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXNavigationBar : UXBar

@property (nonatomic, getter = isTranslucent) BOOL translucent;
@property (nonatomic, copy, nullable) NSArray<UXNavigationItem *> *items;
@property (nonatomic, weak, nullable) id <UXNavigationBarDelegate> delegate;
@property (nonatomic, readonly, nullable) UXNavigationItem *backItem;
@property (nonatomic, readonly, nullable) UXNavigationItem *topItem;

- (void)pushNavigationItem:(UXNavigationItem *)navigationItem animated:(BOOL)animated NS_SWIFT_NAME(pushItem(_:animated:));
- (nullable UXNavigationItem *)popNavigationItemAnimated:(BOOL)animated NS_SWIFT_NAME(popItem(animated:));

@end

NS_HEADER_AUDIT_END(nullability, sendability)
