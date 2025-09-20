#import <AppKit/AppKit.h>
#import <UXKit/UXBarCommon.h>
#import <UXKit/UXKitDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

typedef NS_OPTIONS(NSUInteger, UXRectEdge) {
    UXRectEdgeNone   = 0,
    UXRectEdgeTop    = 1 << 0,
    UXRectEdgeLeft   = 1 << 1,
    UXRectEdgeBottom = 1 << 2,
    UXRectEdgeRight  = 1 << 3,
    UXRectEdgeAll    = UXRectEdgeTop | UXRectEdgeLeft | UXRectEdgeBottom | UXRectEdgeRight
};

typedef NS_ENUM(NSInteger, UXModalPresentationStyle) {
    UXModalPresentationFullScreen = 0,
    UXModalPresentationPageSheet,
    UXModalPresentationFormSheet,
    UXModalPresentationCurrentContext,
    UXModalPresentationCustom,
    UXModalPresentationOverFullScreen,
    UXModalPresentationOverCurrentContext,
    UXModalPresentationPopover,
    UXModalPresentationBlurOverFullScreen,
    UXModalPresentationNone      = -1,
    UXModalPresentationAutomatic = -2,
};

@class UXNavigationController, UXNavigationItem, UXSourceController, UXTabBarController, UXTabBarItem, UXView, UXWindowController, UXTabBarItemSegment, UXPopoverController, UXBarButtonItem;
@protocol UXLayoutSupport, UXNavigationDestination, UXViewControllerTransitionCoordinator;

UXKIT_EXTERN NS_SWIFT_UI_ACTOR
@interface UXViewController : NSViewController
@property (nonatomic, class, readonly) Class viewClass;
@property (nonatomic) BOOL automaticallyAdjustsScrollViewInsets;
@property (nonatomic) UXModalPresentationStyle modalPresentationStyle;
@property (nonatomic, getter = isEditing) BOOL editing;
@property (nonatomic, readonly, nullable) UXViewController *ux_presentingViewController;
@property (nonatomic, readonly, nullable) UXViewController *ux_parentViewController;
@property (nonatomic, readonly, nullable) UXViewController *presentedViewController;
@property (nonatomic, readonly, nullable) id<UXViewControllerTransitionCoordinator> transitionCoordinator;
@property (nonatomic, readonly) UXView *uxView;
@property (nonatomic, readonly) id<UXLayoutSupport> topLayoutGuide;
@property (nonatomic, readonly) id<UXLayoutSupport> bottomLayoutGuide;
@property (nonatomic, strong, readonly, nullable) NSView *viewIfLoaded;

- (void)invalidateIntrinsicLayoutInsets;
- (NSEdgeInsets)intrinsicLayoutInsets;

- (void)setEditing:(BOOL)editing animated:(BOOL)animated;
- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^ __nullable)(void))completion NS_SWIFT_DISABLE_ASYNC;
- (void)presentViewController:(UXViewController *)viewController animated:(BOOL)animated completion:(void (^ __nullable)(void))completion NS_SWIFT_DISABLE_ASYNC;
- (void)didMoveToParentViewController:(nullable UXViewController *)parent NS_SWIFT_NAME(didMove(toParent:));
- (void)willMoveToParentViewController:(nullable UXViewController *)parent NS_SWIFT_NAME(willMove(toParent:));
- (void)removeChildViewControllerAtIndex:(NSInteger)index;

- (void)viewDidLiveResize;
- (void)viewWillLiveResize;
- (void)viewDidLayoutSubviews;
- (void)viewWillLayoutSubviews;
@end

@interface UXViewController (UXNavigationControllerItem)
@property (nonatomic) BOOL hidesBottomBarWhenPushed;
@property (nonatomic, strong, nullable) UXViewController *toolbarViewController;
@property (nonatomic, strong, nullable) NSArray<__kindof UXBarButtonItem *> *toolbarItems;
@property (nonatomic, strong, nullable) NSArray<__kindof UXBarButtonItem *> *subtoolbarItems;
@property (nonatomic, strong, readonly, nullable) UXNavigationItem *navigationItem;
@property (nonatomic, strong, readonly, nullable) UXNavigationController *navigationController;
@property (nonatomic, strong, nullable) UXViewController *accessoryViewController;
@property (nonatomic, strong, nullable) NSArray<__kindof UXBarButtonItem *> *accessoryBarItems;
@property (nonatomic, readonly) UXBarPosition preferredToolbarPosition;
- (void)setToolbarItems:(nullable NSArray<UXBarButtonItem *> *)toolbarItems animated:(BOOL)animated;
@end

@interface UXViewController (Compatibility)
- (void)viewDidDisappear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;
- (void)viewDidAppear:(BOOL)animated;
- (void)viewWillAppear:(BOOL)animated;
@property (nonatomic, readonly) NSInteger interfaceOrientation;
@end

@interface UXViewController (UXPopoverController)
@property (nonatomic, readonly, nullable) UXPopoverController *popoverController;
@end



NS_HEADER_AUDIT_END(nullability, sendability)
