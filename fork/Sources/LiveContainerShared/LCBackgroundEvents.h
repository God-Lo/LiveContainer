//
//  LCBackgroundEvents.h
//  LiveContainer (fork)
//
//  Background events for apps, as iOS gives them to native apps. Off by default; turned on per app
//  under App Extensions ("Background Events").
//
//  iOS only wakes LiveContainer itself. So LiveContainer stands in for the apps:
//  - Recording (in the app's process): what the app registers with iOS: Bluetooth restore IDs and
//    connection-event filters, significant-location and region monitoring, background task IDs and
//    requests. Kept per app in the app group (LiveContainer/BackgroundEvents/<folder>.plist).
//  - Listening (LiveContainer's own process): the same registrations, made by LiveContainer, plus
//    accessory connections for the apps' accessory protocols.
//  - Delivering: each event goes to the apps that registered for it. The app runs in LiveProcess, as
//    for Shortcuts actions, and LiveContainer calls its own delegates and task handlers there. Accessory
//    sessions are opened by LiveContainer and relayed to the app's EASession streams.
//
//  On rebuild, the apps' background modes, accessory protocols, background task IDs and missing
//  permission texts are added to LiveContainer's Info.plist (LCGuestExtensionBuilder).
//

#import <Foundation/Foundation.h>

/// Info.plist keys merged from the apps on rebuild.
static inline NSArray<NSString *> *LCBackgroundEventsListKeys(void) {
    return @[@"UIBackgroundModes", @"UISupportedExternalAccessoryProtocols", @"BGTaskSchedulerPermittedIdentifiers"];
}

/// Folder in LiveContainer's app group: apps.plist (folders with Background Events on) and one
/// <folder>.plist per app with what it registered.
NSString *LCBackgroundEventsFolder(void);

#pragma mark - LiveContainer (host)

/// Starts listening on the apps' behalf. Call from LiveContainer's application:didFinishLaunching:,
/// which background task handlers must be registered in.
void LCBackgroundEventsHostStart(NSDictionary *launchOptions);

#pragma mark - App (guest, in LiveProcess)

@protocol LCGuestIntentHost;
/// Called by the guest side of the connection (LCGuestIntentClient) once it's set up.
void LCBackgroundEventsGuestConnect(id<LCGuestIntentHost> (^host)(BOOL synchronous), NSData *accessories);
void LCBackgroundEventsGuestDeliver(NSData *event);
void LCBackgroundEventsGuestAccessoryData(NSString *session, NSData *data);
void LCBackgroundEventsGuestAccessoryClosed(NSString *session);
