//
//  LCGuestExtension.h
//  LiveContainer (fork)
//
//  Runs apps' own app extensions through LiveContainer's extensions. LiveContainer ships one extension
//  per supported kind (broadcast, share, action, keyboard, Safari content blocker, File Provider,
//  widgets). When iOS starts one, it loads the matching extension code of an app installed in
//  LiveContainer and runs it in that app's environment (home folder, UserDefaults, app groups).
//
//  LiveContainer prepares each app's extension executable as a signed dylib (LCExtension.dylib inside
//  the app's .appex) and records it in the shared app-group defaults, so nothing needs turning on.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Shared defaults key: { extension point: { app folder: entry } }.
static NSString *const kLCGuestExtensionsKey = @"LCGuestExtensions";
/// Shared defaults key: { extension point: app folder } for kinds where the user picked one app (widgets).
static NSString *const kLCGuestExtensionChoiceKey = @"LCGuestExtensionChoice";
/// Shared defaults key: { File Provider domain identifier: app bundle ID }.
static NSString *const kLCFileProviderDomainsKey = @"LCFileProviderDomains";

// Entry keys
static NSString *const kLCGEBundleId = @"bundleId";
static NSString *const kLCGEName = @"name";
static NSString *const kLCGEFolder = @"folder";
static NSString *const kLCGEIsShared = @"isShared";
static NSString *const kLCGEAppex = @"appex";
static NSString *const kLCGEPrincipalClass = @"principalClass";
static NSString *const kLCGEStoryboard = @"storyboard";

/// The extension executable converted to a signed dylib, inside the app's .appex.
static NSString *const kLCGuestExtensionDylibName = @"LCExtension.dylib";

// Supported extension points
static NSString *const kLCPointBroadcast = @"com.apple.broadcast-services-upload";
static NSString *const kLCPointShare = @"com.apple.share-services";
static NSString *const kLCPointAction = @"com.apple.ui-services";
static NSString *const kLCPointKeyboard = @"com.apple.keyboard-service";
static NSString *const kLCPointContentBlocker = @"com.apple.Safari.content-blocker";
static NSString *const kLCPointFileProvider = @"com.apple.fileprovider-nonui";
static NSString *const kLCPointWidgets = @"com.apple.widgetkit-extension";
static NSString *const kLCPointPhotoEditing = @"com.apple.photo-editing";
static NSString *const kLCPointMessages = @"com.apple.message-payload-provider";
static NSString *const kLCPointCallDirectory = @"com.apple.callkit.call-directory";
static NSString *const kLCPointMessageFilter = @"com.apple.identitylookup.message-filter";

static inline NSArray<NSString *> *LCGuestExtensionPoints(void) {
    return @[kLCPointBroadcast, kLCPointShare, kLCPointAction, kLCPointKeyboard, kLCPointContentBlocker,
             kLCPointFileProvider, kLCPointWidgets, kLCPointPhotoEditing, kLCPointMessages,
             kLCPointCallDirectory, kLCPointMessageFilter];
}

static inline NSString *LCGuestExtensionKindName(NSString *point) {
    return @{kLCPointBroadcast: @"Screen Broadcast", kLCPointShare: @"Share", kLCPointAction: @"Actions",
             kLCPointKeyboard: @"Keyboard", kLCPointContentBlocker: @"Safari Content Blocker",
             kLCPointFileProvider: @"Files", kLCPointWidgets: @"Widgets",
             kLCPointPhotoEditing: @"Photo Editing", kLCPointMessages: @"iMessage",
             kLCPointCallDirectory: @"Call Blocking", kLCPointMessageFilter: @"SMS Filter"}[point] ?: point;
}

/// Kinds that can see private data (the screen, what you type, your messages). An app's extension of
/// these kinds runs only after you allow it in the app's settings in LiveContainer.
static inline BOOL LCGuestExtensionIsSensitive(NSString *point) {
    return [@[kLCPointBroadcast, kLCPointKeyboard, kLCPointMessageFilter] containsObject:point];
}

/// Shared defaults key: { app folder: { extension point: allowed } }. Missing means the default:
/// allowed, except for sensitive kinds.
static NSString *const kLCGuestExtensionPermissionsKey = @"LCGuestExtensionPermissions";

BOOL LCGuestExtensionIsAllowed(NSUserDefaults *sharedDefaults, NSString *folder, NSString *point);

/// Apps that have an extension of this kind, the one to use first: the app picked for this kind if
/// any, otherwise the app opened most recently. Entries are resolved and include "bundlePath".
NSArray<NSDictionary *> *LCGuestExtensionCandidates(NSString *point, NSString *_Nullable *_Nullable error);

/// Sets up the app's environment in this process and loads its extension code. Only one app's
/// extension can be loaded per process. Returns NO with a reason on failure.
BOOL LCGuestExtensionLoad(NSDictionary *entry, NSString *_Nullable *_Nullable error);

/// Picks the first candidate for this kind, loads it and returns its principal class.
Class _Nullable LCGuestExtensionLoadPrincipalClass(NSString *point, NSString *_Nullable *_Nullable error);

/// Bundle ID of the app that added this File Provider domain, if known.
NSString *_Nullable LCGuestExtensionFileProviderOwner(NSString *domainIdentifier);

/// The app loaded in this process, if any.
NSDictionary *_Nullable LCGuestExtensionLoadedEntry(void);

/// Calls the loaded app extension's own main(). Returns -1 if it has none.
int LCGuestExtensionRunMain(int argc, char *_Nullable *_Nullable argv);

NS_ASSUME_NONNULL_END
