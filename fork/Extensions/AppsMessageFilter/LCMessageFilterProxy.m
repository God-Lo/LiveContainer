//
//  LCMessageFilterProxy.m
//  LiveContainer (fork)
//
//  SMS filter "LiveContainer": runs the message filter of the app opened most recently among the
//  apps allowed to use SMS Filter in LiveContainer.
//

@import IdentityLookup;
#import "../Common/LCExtensionProxy.h"

@interface LCMessageFilterProxy : ILMessageFilterExtension <ILMessageFilterQueryHandling>
@end

@implementation LCMessageFilterProxy

LC_PROXY_ALLOC(kLCPointMessageFilter, ILMessageFilterExtension.class)

// Only reached when no app's filter could be loaded: filter nothing.
- (void)handleQueryRequest:(ILMessageFilterQueryRequest *)queryRequest context:(ILMessageFilterExtensionContext *)context
                completion:(void (^)(ILMessageFilterQueryResponse *))completion {
    ILMessageFilterQueryResponse *response = [ILMessageFilterQueryResponse new];
    response.action = ILMessageFilterActionNone;
    completion(response);
}

@end
