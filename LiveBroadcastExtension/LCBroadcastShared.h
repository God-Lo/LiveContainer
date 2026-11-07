//
//  LCBroadcastShared.h
//  LiveContainer (fork)
//
//  Contract between LiveContainer (which prepares apps' broadcast code) and
//  LiveBroadcastExtension (which loads it). Stored in LiveContainer's shared app-group defaults.
//

#import <Foundation/Foundation.h>

/// NSDictionary folder -> entry for every app whose broadcast extension is prepared. The broadcast runs
/// the one from the app opened most recently (lastLaunched in its LCAppInfo.plist).
static NSString *const kLCBroadcastGuestsKey = @"LCBroadcastGuests";
static NSString *const kLCBroadcastBundleId = @"bundleId";       // guest bundle ID
static NSString *const kLCBroadcastFolder = @"folder";           // folder under Applications
static NSString *const kLCBroadcastIsShared = @"isShared";       // NSNumber: app lives in the app group
static NSString *const kLCBroadcastAppex = @"appex";             // e.g. "Upload.appex" inside the guest's PlugIns
static NSString *const kLCBroadcastPrincipalClass = @"principalClass";
/// File name, inside the guest appex, of its executable converted to a signed dylib.
static NSString *const kLCBroadcastDylibName = @"LCBroadcast.dylib";
