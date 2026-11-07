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

/// In display order.
static inline NSArray<NSString *> *LCGuestExtensionPoints(void) {
    return @[kLCPointWidgets, kLCPointShare, kLCPointAction, kLCPointFileProvider, kLCPointContentBlocker,
             kLCPointPhotoEditing, kLCPointMessages, kLCPointCallDirectory, kLCPointKeyboard,
             kLCPointBroadcast, kLCPointMessageFilter];
}

static inline NSString *LCGuestExtensionKindName(NSString *point) {
    return @{kLCPointBroadcast: @"Screen Broadcast", kLCPointShare: @"Share", kLCPointAction: @"Actions",
             kLCPointKeyboard: @"Keyboard", kLCPointContentBlocker: @"Safari Content Blocker",
             kLCPointFileProvider: @"Files", kLCPointWidgets: @"Widgets",
             kLCPointPhotoEditing: @"Photo Editing", kLCPointMessages: @"iMessage",
             kLCPointCallDirectory: @"Call Blocking", kLCPointMessageFilter: @"SMS Filter"}[point] ?: point;
}

/// Kinds LiveContainer offers for one app at a time (iOS allows one per app, or one is all that makes
/// sense): the app is picked in Settings, and iOS sees them under LiveContainer's own name.
static inline BOOL LCGuestExtensionIsSingleApp(NSString *point) {
    return [@[kLCPointFileProvider, kLCPointMessages, kLCPointMessageFilter, kLCPointBroadcast] containsObject:point];
}
