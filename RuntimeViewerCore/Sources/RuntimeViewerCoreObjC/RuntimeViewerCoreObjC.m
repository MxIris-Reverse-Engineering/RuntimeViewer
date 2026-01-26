//
//  RuntimeViewerObjC.m
//  Core
//
//  Created by JH on 11/12/25.
//

#import "RuntimeViewerCoreObjC.h"

const void * _Nullable RVClassFromString(NSString *className) {
    return (__bridge void * _Nullable)(NSClassFromString(className));
}

const void * _Nullable RVProtocolFromString(NSString *protocolName) {
    return (__bridge void * _Nullable)(NSProtocolFromString(protocolName));
}
