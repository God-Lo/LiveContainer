//
//  LCMessagesProxy.m
//  LiveContainer (fork)
//
//  iMessage app "LiveContainer": runs the iMessage app of the app opened most recently.
//

@import Messages;
#import "../Common/LCExtensionProxy.h"

@interface LCMessagesProxy : MSMessagesAppViewController
@end

@implementation LCMessagesProxy

LC_PROXY_ALLOC(kLCPointMessages, MSMessagesAppViewController.class)

// Only shown when no app's iMessage app could be loaded.
- (void)viewDidLoad {
    [super viewDidLoad];
    UILabel *label = [UILabel new];
    label.text = LCProxyError;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.frame = CGRectInset(self.view.bounds, 24, 24);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:label];
}

@end
