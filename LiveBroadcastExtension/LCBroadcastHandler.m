//
//  LCBroadcastHandler.m
//  LiveBroadcastExtension (fork)
//
//  LiveContainer's single ReplayKit broadcast upload extension ("LiveContainer" in the system screen
//  broadcast picker). It runs the broadcast extension of the app with one that was opened most recently
//  in LiveContainer (every such app is prepared automatically): it sets up that app's environment the way LiveContainer does for the app itself
//  (home folder, UserDefaults, app group containers), loads the app's broadcast code, and lets iOS use
//  the app's own RPBroadcastSampleHandler subclass as this extension's principal object.
//

@import ReplayKit;
#import <dlfcn.h>
#import "LCBroadcastShared.h"
#import "../LiveContainer/LCSharedUtils.h"
#import "../LiveContainer/Tweaks/Tweaks.h"

extern NSUserDefaults *lcUserDefaults;
extern NSUserDefaults *lcSharedDefaults;
extern NSString *lcAppGroupPath;
extern NSDictionary *guestAppInfo;
extern NSDictionary *guestContainerInfo;
extern NSString *lcGuestAppId;
extern bool isSharedBundle;

static NSString *loadError;

static Class loadGuestBroadcastClass(void) {
    NSString *groupId = [LCSharedUtils appGroupID];
    if (!groupId) { loadError = @"LiveContainer has no app group. Reinstall it with its app group."; return nil; }
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:groupId];
    lcAppGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupId].path;

    NSDictionary *guests = [lcSharedDefaults dictionaryForKey:kLCBroadcastGuestsKey];
    if (!guests.count) {
        loadError = @"None of your apps in LiveContainer has a screen broadcast extension (or LiveContainer's JIT-less signing certificate isn't set up). Open LiveContainer once after installing one.";
        return nil;
    }
    // Folder holding Applications/ and Data/: the app group for shared apps, LiveContainer's
    // Documents otherwise (extensions can't see it directly; LiveContainer leaves a bookmark).
    NSString *sharedRoot = [lcAppGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    NSString *privateRoot = nil;
    NSData *bookmark = [lcSharedDefaults dataForKey:@"LCLaunchExtensionPrivateDocBookmark"];
    BOOL stale = NO;
    NSURL *docs = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
    if (docs && [docs startAccessingSecurityScopedResource]) privateRoot = docs.path;

    // Run the broadcast of the app opened most recently.
    NSDictionary *sel = nil;
    NSString *lcRoot = nil;
    NSDate *newest = nil;
    for (NSDictionary *entry in guests.allValues) {
        NSString *root = [entry[kLCBroadcastIsShared] boolValue] ? sharedRoot : privateRoot;
        if (!root) continue;
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:
            [root stringByAppendingFormat:@"/Applications/%@/LCAppInfo.plist", entry[kLCBroadcastFolder]]];
        if (!appInfo) continue;
        NSDate *launched = [appInfo[@"lastLaunched"] isKindOfClass:NSDate.class] ? appInfo[@"lastLaunched"] : NSDate.distantPast;
        if (!sel || [launched compare:newest] == NSOrderedDescending) { sel = entry; lcRoot = root; newest = launched; }
    }
    if (!sel) {
        loadError = privateRoot ? @"The apps set up for screen broadcast are no longer installed in LiveContainer."
                                : @"Can't reach LiveContainer's apps. Open LiveContainer once, then try again.";
        return nil;
    }
    BOOL shared = [sel[kLCBroadcastIsShared] boolValue];
    if (!shared) setenv("LC_HOME_PATH", docs.URLByDeletingLastPathComponent.path.fileSystemRepresentation, 1);

    NSString *bundlePath = [lcRoot stringByAppendingFormat:@"/Applications/%@", sel[kLCBroadcastFolder]];
    guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (!guestAppInfo || !info) {
        loadError = [NSString stringWithFormat:@"%@ is no longer installed in LiveContainer.", sel[kLCBroadcastBundleId]];
        return nil;
    }

    // Same home and identity as when LiveContainer runs the app, so UserDefaults and app groups match.
    isSharedBundle = shared;
    lcGuestAppId = [guestAppInfo[@"doUseLCBundleId"] boolValue] ? guestAppInfo[@"LCOrignalBundleIdentifier"] : info[@"CFBundleIdentifier"];
    NSString *home = [lcRoot stringByAppendingFormat:@"/Data/Application/%@", guestAppInfo[@"LCDataUUID"]];
    setenv("CFFIXED_USER_HOME", home.fileSystemRepresentation, 1);
    setenv("HOME", home.fileSystemRepresentation, 1);
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
    NUDGuestHooksInit();
    NSFMGuestHooksInit();

    NSString *appexPath = [bundlePath stringByAppendingFormat:@"/PlugIns/%@", sel[kLCBroadcastAppex]];
    NSString *dylib = [appexPath stringByAppendingPathComponent:kLCBroadcastDylibName];
    if (!dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        loadError = [NSString stringWithFormat:@"Couldn't load the app's broadcast code: %s. Open LiveContainer to prepare it again.", dlerror()];
        return nil;
    }
    Class cls = NSClassFromString(sel[kLCBroadcastPrincipalClass]);
    if (!cls) loadError = [NSString stringWithFormat:@"The app's broadcast class %@ wasn't found.", sel[kLCBroadcastPrincipalClass]];
    NSLog(@"[LCBroadcast] guest %@ class %@ error %@", sel[kLCBroadcastBundleId], cls, loadError);
    return cls;
}

@interface LCBroadcastHandler : RPBroadcastSampleHandler
@end

@implementation LCBroadcastHandler

static Class guestClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = loadGuestBroadcastClass(); });
    return cls;
}

// iOS creates the principal object with +alloc/-init; hand it the app's own handler instead.
+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    Class cls = guestClass();
    if (cls && cls != self && [cls isSubclassOfClass:RPBroadcastSampleHandler.class]) {
        return [cls allocWithZone:zone];
    }
    return [super allocWithZone:zone];
}

// Only reached when the app's handler couldn't be loaded: end the broadcast with the reason.
- (void)broadcastStartedWithSetupInfo:(NSDictionary<NSString *, NSObject *> *)setupInfo {
    NSString *message = loadError ?: @"LiveContainer couldn't start the app's screen broadcast.";
    [self finishBroadcastWithError:[NSError errorWithDomain:@"LiveContainer.Broadcast" code:1
                                                   userInfo:@{NSLocalizedDescriptionKey: message}]];
}

- (void)processSampleBuffer:(CMSampleBufferRef)sampleBuffer withType:(RPSampleBufferType)sampleBufferType {}

@end
