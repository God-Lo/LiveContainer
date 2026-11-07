//
//  LCBroadcastHandler.m
//  LiveBroadcastExtension (fork)
//
//  LiveContainer's ReplayKit broadcast upload extension ("LiveContainer" in the screen broadcast
//  picker). Runs the broadcast extension of the app opened most recently among the apps allowed to use
//  Screen Broadcast (see LCGuestExtension.h).
//

@import ReplayKit;
#import "../Common/LCExtensionProxy.h"

@interface LCBroadcastHandler : RPBroadcastSampleHandler
@end

@implementation LCBroadcastHandler

LC_PROXY_ALLOC(kLCPointBroadcast, RPBroadcastSampleHandler.class)

// Only reached when the app's handler couldn't be loaded: end the broadcast with the reason.
- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    [self finishBroadcastWithError:[NSError errorWithDomain:@"LiveContainer.Broadcast" code:1
                                                   userInfo:@{NSLocalizedDescriptionKey: LCProxyError ?: @"LiveContainer couldn't start the app's screen broadcast."}]];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {}

@end
