#import <AppKit/AppKit.h>

@protocol UXLayoutSupport <NSObject>

@property (readonly) NSLayoutDimension *heightAnchor;
@property (readonly) NSLayoutYAxisAnchor *bottomAnchor;
@property (readonly) NSLayoutYAxisAnchor *topAnchor;
@property (nonatomic) CGFloat length;

@end
