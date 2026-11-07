//
//  LCContentBlockerProxy.m
//  LiveContainer (fork)
//
//  Safari content blocker "LiveContainer": runs the content blocker of the app opened most
//  recently. Apps reload it as usual; LiveContainer points their reload at this blocker.
//

@import Foundation;
@import UniformTypeIdentifiers;
#import "../Common/LCExtensionProxy.h"

@interface LCContentBlockerProxy : NSObject <NSExtensionRequestHandling>
@end

@implementation LCContentBlockerProxy

LC_PROXY_ALLOC(kLCPointContentBlocker, nil)

// Only reached when no app's blocker could be loaded: block nothing.
- (void)beginRequestWithExtensionContext:(NSExtensionContext *)context {
    NSData *rules = [@"[{\"trigger\":{\"url-filter\":\"^lc-no-rules:\"},\"action\":{\"type\":\"block\"}}]" dataUsingEncoding:NSUTF8StringEncoding];
    NSExtensionItem *item = [NSExtensionItem new];
    item.attachments = @[[[NSItemProvider alloc] initWithItem:rules typeIdentifier:UTTypeJSON.identifier]];
    [context completeRequestReturningItems:@[item] completionHandler:nil];
}

@end
