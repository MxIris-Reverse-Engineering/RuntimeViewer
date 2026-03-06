#ifdef DEBUG

#import "RuntimeViewerDebugger.h"

@interface RuntimeViewerDebuggerMenuItem: NSMenuItem

+ (void)insertInMainMenu;

@end

@implementation RuntimeViewerDebugger

+ (void)load
{
    NSMutableDictionary *argValues = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain].mutableCopy;
    argValues[@"_NS_4445425547"] = @(YES);

    [[NSUserDefaults standardUserDefaults] setVolatileDomain:argValues forName:NSArgumentDomain];

    [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification * _Nonnull note) {
        [RuntimeViewerDebuggerMenuItem insertInMainMenu];
    }];
}


@end

@implementation RuntimeViewerDebuggerMenuItem

+ (void)insertInMainMenu
{
    [[[NSApplication sharedApplication] mainMenu] addItem:[[self alloc] init]];
}


- (id)init
{
    return [self initWithTitle:@"Debug" action:@selector(submenuAction:) keyEquivalent:@""];
}

- (id)initWithTitle:(NSString *)itemName action:(SEL)anAction keyEquivalent:(NSString *)charCode
{
    if (self = [super initWithTitle:itemName action:anAction keyEquivalent:charCode])
    {
        NSMenu *submenu = [[NSMenu alloc] initWithTitle:@"Debug"];
        
        NSMenuItem *item1 = [[NSMenuItem alloc] initWithTitle:@"Visualize Constraints" action:@selector(visualizeConstraints:) keyEquivalent:@""];
        [item1 setTarget:self];
        [submenu addItem:item1];

        [self setSubmenu:submenu];
        
        return self;
    }
    return nil;
}

- (IBAction)visualizeConstraints:(id)sender
{
    NSWindow *window = [NSApp mainWindow];
    NSView *firstResponderView = (NSView *)window.firstResponder;

    if ([firstResponderView respondsToSelector:@selector(constraints)]) {
        [window visualizeConstraints:firstResponderView.constraints];
    } else {
        [window visualizeConstraints:window.contentView.constraints];
    }
}

@end

#endif
