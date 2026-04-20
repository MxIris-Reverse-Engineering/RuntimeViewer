#ifdef DEBUG

#import "RuntimeViewerDebugger.h"

@implementation RuntimeViewerDebugger

+ (void)load {
    NSMutableDictionary *argValues = [[NSUserDefaults standardUserDefaults] volatileDomainForName:NSArgumentDomain].mutableCopy;
    argValues[@"_NS_4445425547"] = @(YES);

    [[NSUserDefaults standardUserDefaults] setVolatileDomain:argValues forName:NSArgumentDomain];
}


@end


#endif
