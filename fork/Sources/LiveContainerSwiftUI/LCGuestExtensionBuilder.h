//
//  LCGuestExtensionBuilder.h
//  LiveContainer (fork)
//
//  Copies apps' extensions into LiveContainer during its on-device rebuild (see LCGuestExtension.h).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCGuestExtensionBuilder : NSObject
/// Extension points of the app's extensions that LiveContainer can run, in display order.
+ (NSArray<NSString *> *)supportedPointsInBundle:(NSString *)bundlePath;
+ (NSString *)displayNameForPoint:(NSString *)point;
/// iOS allows one extension of this kind per app, so only one app can use it at a time.
+ (BOOL)isSingleAppPoint:(NSString *)point;
+ (NSArray<NSString *> *)allPoints;

/// apps: [{ bundlePath, folder, isShared, name, points: [extension point] }].
/// Fingerprint of what the rebuild would contain ("" when nothing).
+ (NSString *)signatureForApps:(NSArray<NSDictionary *> *)apps;
/// Fingerprint of what the running LiveContainer contains ("" when nothing).
+ (NSString *)installedSignature;
/// App folders whose extensions the running LiveContainer contains.
+ (NSSet<NSString *> *)installedFolders;
/// Replaces the copied extensions in `app` (a writable copy of LiveContainer.app) with these apps'.
+ (BOOL)addExtensionsOfApps:(NSArray<NSDictionary *> *)apps toApp:(NSURL *)app error:(NSError **)error;
/// Removes what earlier builds of this fork left in apps' bundles and shared settings.
+ (void)removeLeftoversInApps:(NSArray<NSString *> *)bundlePaths;
@end

NS_ASSUME_NONNULL_END
