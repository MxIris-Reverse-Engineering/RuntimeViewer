//
//  main.m
//  RuntimeViewerServer
//
//  Created by JH on 11/27/24.
//

#import <Foundation/Foundation.h>
#import <RuntimeViewerMobileServer-Swift.h>

static void __attribute__((constructor)) runtime_viewer_server_main(void) {
    [RuntimeViewerServerLoader main];
}
