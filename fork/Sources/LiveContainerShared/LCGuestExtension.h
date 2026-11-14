//
//  LCGuestExtension.h
//  LiveContainer (fork)
//
//  Apps' extensions inside LiveContainer. When an app's feature is turned on in its settings,
//  LiveContainer's on-device rebuild (LCSelfUpdate) copies that app's own extension into
//  LiveContainer's PlugIns, the same way Shortcuts actions are added. Each copy keeps its own name,
//  resources and code, gets its own ID under LiveContainer, and loads LiveContainerShared, which sets
//  up the app's environment when the extension starts (LCGuestExtensionRuntime.m).
//

#import <Foundation/Foundation.h>

/// Info.plist key of a copied extension: { folder, isShared, appBundleId, appexBundleId, appName }.
static NSString *const kLCGuestExtensionInfoKey = @"LCGuestExtension";
static NSString *const kLCGEFolder = @"folder";
static NSString *const kLCGEIsShared = @"isShared";
static NSString *const kLCGEAppBundleId = @"appBundleId";
static NSString *const kLCGEAppexBundleId = @"appexBundleId";
static NSString *const kLCGEAppName = @"appName";

// Supported extension points
static NSString *const kLCPointWidgets = @"com.apple.widgetkit-extension";
static NSString *const kLCPointShare = @"com.apple.share-services";
static NSString *const kLCPointAction = @"com.apple.ui-services";
static NSString *const kLCPointFileProvider = @"com.apple.fileprovider-nonui";
static NSString *const kLCPointContentBlocker = @"com.apple.Safari.content-blocker";
static NSString *const kLCPointPhotoEditing = @"com.apple.photo-editing";
static NSString *const kLCPointMessages = @"com.apple.message-payload-provider";
static NSString *const kLCPointCallDirectory = @"com.apple.callkit.call-directory";
static NSString *const kLCPointKeyboard = @"com.apple.keyboard-service";
static NSString *const kLCPointBroadcast = @"com.apple.broadcast-services-upload";
static NSString *const kLCPointMessageFilter = @"com.apple.identitylookup.message-filter";
/// Not an extension: the app's AccessorySetupKit settings (NSAccessorySetup* in its Info.plist), which
/// iOS reads from LiveContainer's Info.plist, so the rebuild adds them there.
static NSString *const kLCPointAccessorySetup = @"lc.accessory-setup";

/// In display order.
static inline NSArray<NSString *> *LCGuestExtensionPoints(void) {
    return @[kLCPointWidgets, kLCPointShare, kLCPointAction, kLCPointFileProvider, kLCPointContentBlocker,
             kLCPointPhotoEditing, kLCPointMessages, kLCPointCallDirectory, kLCPointKeyboard,
             kLCPointBroadcast, kLCPointMessageFilter, kLCPointAccessorySetup];
}

static inline NSString *LCGuestExtensionKindName(NSString *point) {
    return @{kLCPointBroadcast: @"Screen Broadcast", kLCPointShare: @"Share", kLCPointAction: @"Actions",
             kLCPointKeyboard: @"Keyboard", kLCPointContentBlocker: @"Safari Content Blocker",
             kLCPointFileProvider: @"Files", kLCPointWidgets: @"Widgets",
             kLCPointPhotoEditing: @"Photo Editing", kLCPointMessages: @"iMessage",
             kLCPointCallDirectory: @"Call Blocking", kLCPointMessageFilter: @"SMS Filter",
             kLCPointAccessorySetup: @"Accessory Setup"}[point] ?: point;
}

/// Kinds iOS allows once per app, so LiveContainer offers them for one app at a time: the app is picked
/// in Settings, and iOS sees them under LiveContainer's own name.
static inline BOOL LCGuestExtensionIsSingleApp(NSString *point) {
    return [@[kLCPointMessages, kLCPointMessageFilter] containsObject:point];
}

/// Kinds iOS allows or shows only once per app even when there are several: share extensions and File
/// Providers. These are kept inside LiveContainer without registering them with iOS
/// (LCGuestExtensions/*.lcext), and LiveContainer's own extension of that kind runs them: its share menu
/// lists them under "Share With", and its File Provider runs each app's in that app's location.
static NSString *const kLCHostedExtensionsFolder = @"LCGuestExtensions";
/// An app's hosted extension executable, converted to a library LiveContainer's extension can load.
static NSString *const kLCHostedDylibName = @"LCExtension.dylib";
static inline BOOL LCGuestExtensionIsHosted(NSString *point) {
    return [@[kLCPointShare, kLCPointFileProvider] containsObject:point];
}

/// Hosted extensions of this kind in the running LiveContainer: each is its Info.plist plus "path".
NSArray<NSDictionary *> *LCHostedGuestExtensions(NSString *point);
/// Sets up the app's environment in this process and loads the hosted extension's code; afterwards
/// Bundle.main is the extension's bundle. One app per process. Returns NO with a reason on failure.
BOOL LCLoadHostedGuestExtension(NSDictionary *entry, NSString *_Nullable *_Nullable error);
/// For extensions that serve several apps in one process (File Providers): loads the extension's code
/// even when another app's already runs here. The first app sets up the environment; later ones share
/// it, so they reach their app groups but not their own home folder or settings. Code already loaded
/// for the same extension (another copy of the app) is reused.
BOOL LCLoadHostedGuestExtensionCode(NSDictionary *entry, NSString *_Nullable *_Nullable error);
