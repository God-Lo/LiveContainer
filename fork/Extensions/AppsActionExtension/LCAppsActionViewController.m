//
//  LCAppsActionViewController.m
//  LiveContainer (fork)
//
//  Action entry "LiveContainer Apps": runs the action extension of an app in LiveContainer
//  (asks which one when several apps have one).
//

#import "../Common/LCAppsUIExtension.h"

@interface LCAppsActionViewController : LCAppsUIExtensionViewController
@end

@implementation LCAppsActionViewController
- (NSString *)extensionPoint { return kLCPointAction; }
@end
