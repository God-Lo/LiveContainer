//
//  LCAppsShareViewController.m
//  LiveContainer (fork)
//
//  Share sheet entry "LiveContainer Apps": runs the share extension of an app in LiveContainer
//  (asks which one when several apps have one).
//

#import "../Common/LCAppsUIExtension.h"

@interface LCAppsShareViewController : LCAppsUIExtensionViewController
@end

@implementation LCAppsShareViewController
- (NSString *)extensionPoint { return kLCPointShare; }
@end
