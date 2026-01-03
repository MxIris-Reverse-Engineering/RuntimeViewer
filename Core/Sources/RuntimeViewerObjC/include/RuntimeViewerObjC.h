//
//  RuntimeViewerObjC.h
//  Core
//
//  Created by JH on 11/12/25.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT
const void * _Nullable RVClassFromString(NSString *className);

FOUNDATION_EXPORT
const void * _Nullable RVProtocolFromString(NSString *protocolName);

NS_ASSUME_NONNULL_END
