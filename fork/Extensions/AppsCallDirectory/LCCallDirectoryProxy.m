//
//  LCCallDirectoryProxy.m
//  LiveContainer (fork)
//
//  Call blocking & identification "LiveContainer": runs the call directory extension of the app
//  opened most recently. Apps reload it as usual; LiveContainer points their reload here.
//

@import CallKit;
#import "../Common/LCExtensionProxy.h"

@interface LCCallDirectoryProxy : CXCallDirectoryProvider
@end

@implementation LCCallDirectoryProxy

LC_PROXY_ALLOC(kLCPointCallDirectory, CXCallDirectoryProvider.class)

// Only reached when no app's extension could be loaded: add nothing.
- (void)beginRequestWithExtensionContext:(CXCallDirectoryExtensionContext *)context {
    [context completeRequestWithCompletionHandler:nil];
}

@end
