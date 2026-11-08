//
//  LCBackgroundEvents.h
//  LiveContainer (fork)
//
//  Background events for one app, as iOS gives them to a native app. Off by default; the app is picked
//  under App Extensions ("Background Events").
//
//  iOS wakes LiveContainer's own process for Bluetooth state restoration and connection events,
//  accessories, location updates and background tasks. When the picked app is set, LiveContainer starts
//  that app instead of its own screen whenever iOS starts it in the background, so the app's own code
//  receives the event: its launch options, its CBCentralManager restore ID, its BGTaskScheduler
//  handlers. Opening LiveContainer while the app runs this way shows LiveContainer again.
//
//  On rebuild, the app's background modes, accessory protocols, background task IDs and missing
//  permission texts are added to LiveContainer's Info.plist (LCGuestExtensionBuilder).
//

#import <Foundation/Foundation.h>

/// Shared settings key: { folder, scheme } of the app that receives background events.
static NSString *const kLCBackgroundEventsAppKey = @"LCBackgroundEventsApp";
/// Shared settings key: when LiveContainer last started the app for a background event.
static NSString *const kLCBackgroundEventsLastStartKey = @"LCBackgroundEventsLastStart";

/// Info.plist keys merged from the app on rebuild.
static inline NSArray<NSString *> *LCBackgroundEventsListKeys(void) {
    return @[@"UIBackgroundModes", @"UISupportedExternalAccessoryProtocols", @"BGTaskSchedulerPermittedIdentifiers"];
}

/// Called once at LiveContainer's start (not in LiveProcess). Returns the app to start: `selectedApp`
/// when one was chosen, the background-events app when iOS started LiveContainer in the background,
/// nil for LiveContainer's own screen.
NSString *LCForkBackgroundLaunchApp(NSString *selectedApp, NSString *urlScheme);
