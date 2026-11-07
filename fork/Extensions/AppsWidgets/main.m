//
//  main.m
//  LiveContainer (fork)
//
//  Widgets "LiveContainer Apps": runs the widget extension (widgets, Live Activities,
//  controls) of one app in LiveContainer: the one picked in its settings, otherwise the one
//  opened most recently. If none can be loaded, shows a placeholder widget.
//

#import <Foundation/Foundation.h>
#import "../Common/LCExtensionProxy.h"

int LCFallbackWidgetsMain(int argc, char **argv);

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *error = nil;
        NSDictionary *entry = LCGuestExtensionCandidates(kLCPointWidgets, &error).firstObject;
        if (entry && LCGuestExtensionLoad(entry, &error)) {
            int ret = LCGuestExtensionRunMain(argc, argv);
            if (ret != -1) return ret;
            error = @"The app's widget extension has no entry point.";
        }
        NSLog(@"[LCGuestExtension] widgets: %@", error);
    }
    return LCFallbackWidgetsMain(argc, argv);
}
