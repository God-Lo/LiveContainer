//
//  LCBackgroundEvents.m
//  LiveContainer (fork)
//

#import "LCBackgroundEvents.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#include <mach/mach.h>
#include <mach/task_policy.h>

/// Whether iOS started this process without showing it (a background launch).
static BOOL launchedInBackground(void) {
    task_category_policy_data_t policy = {0};
    mach_msg_type_number_t count = TASK_CATEGORY_POLICY_COUNT;
    boolean_t getDefault = FALSE;
    if (task_policy_get(mach_task_self(), TASK_CATEGORY_POLICY, (task_policy_t)&policy, &count, &getDefault) != KERN_SUCCESS) return NO;
    switch (policy.role) {
        case TASK_BACKGROUND_APPLICATION:
        case TASK_NONUI_APPLICATION:
        case TASK_DARWINBG_APPLICATION:
            return YES;
        default:
            return NO;
    }
}

NSString *LCForkBackgroundLaunchApp(NSString *selectedApp, NSString *urlScheme) {
    // Set when the app was shown to the user: this start is LiveContainer's own screen.
    NSString *skipMarker = [@(getenv("LC_HOME_PATH") ?: "") stringByAppendingPathComponent:@"tmp/LCBackgroundEventsShowUI"];
    BOOL skip = [NSFileManager.defaultManager fileExistsAtPath:skipMarker];
    if (skip) [NSFileManager.defaultManager removeItemAtPath:skipMarker error:nil];
    if (selectedApp || skip) return selectedApp;

    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    NSDictionary *app = [shared dictionaryForKey:kLCBackgroundEventsAppKey];
    // Several LiveContainers share the settings: only the one the app was picked in.
    if (![app[@"folder"] length] || ![app[@"scheme"] isEqual:urlScheme]) return nil;
    if (!launchedInBackground()) return nil;

    [shared setObject:NSDate.date forKey:kLCBackgroundEventsLastStartKey];
    // The app runs without a window until the user opens LiveContainer: then show LiveContainer, as
    // tapping its icon would. Relaunching is how LiveContainer switches between itself and apps.
    __block id observer = [NSNotificationCenter.defaultCenter addObserverForName:@"UIApplicationDidBecomeActiveNotification" object:nil
                                                                           queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        [NSNotificationCenter.defaultCenter removeObserver:observer];
        [NSFileManager.defaultManager createFileAtPath:skipMarker contents:NSData.data attributes:nil];
        [LCSharedUtils launchToGuestAppWithClassicMode:0];
    }];
    return app[@"folder"];
}
