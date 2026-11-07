//
//  LCForkShare.m
//  LiveContainer (fork)
//

#import "LCForkShare.h"
#import <objc/runtime.h>
#import "../LiveContainerShared/LCGuestExtension.h"

static const void *kHostedContextKey = &kHostedContextKey;

static NSExtensionContext *LCHostedExtensionContext(UIViewController *self, SEL _cmd) {
    return objc_getAssociatedObject(self, kHostedContextKey);
}

@implementation LCForkShare

+ (NSArray<NSDictionary *> *)entries {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *info in LCHostedGuestExtensions(kLCPointShare)) {
        NSMutableDictionary *entry = [info mutableCopy];
        entry[@"name"] = info[@"CFBundleDisplayName"] ?: info[kLCGuestExtensionInfoKey][kLCGEAppName] ?: @"App";
        [result addObject:entry];
    }
    return result;
}

+ (BOOL)openEntry:(NSDictionary *)entry context:(NSExtensionContext *)context from:(UIViewController *)host error:(NSString **)error {
    if (!LCLoadHostedGuestExtension(entry, error)) return NO;
    NSDictionary *ext = entry[@"NSExtension"];
    UIViewController *vc = nil;
    if (ext[@"NSExtensionMainStoryboard"]) {
        vc = [[UIStoryboard storyboardWithName:ext[@"NSExtensionMainStoryboard"] bundle:NSBundle.mainBundle] instantiateInitialViewController];
    } else {
        Class cls = NSClassFromString(ext[@"NSExtensionPrincipalClass"] ?: @"");
        if ([cls isSubclassOfClass:UIViewController.class]) vc = [cls new];
    }
    if (!vc) {
        if (error) *error = [NSString stringWithFormat:@"%@ couldn't be opened.", entry[@"name"]];
        return NO;
    }
    // The app's share screen reads self.extensionContext: give it this share request, so it reads the
    // shared items and completes or cancels the request as it would natively.
    objc_setAssociatedObject(vc, kHostedContextKey, context, OBJC_ASSOCIATION_RETAIN);
    class_replaceMethod(vc.class, @selector(extensionContext), (IMP)LCHostedExtensionContext, "@@:");
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    UIViewController *top = host;
    while (top.presentedViewController) top = top.presentedViewController;
    [top presentViewController:vc animated:YES completion:nil];
    return YES;
}

@end
