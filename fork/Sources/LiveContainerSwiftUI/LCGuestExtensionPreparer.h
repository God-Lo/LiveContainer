//
//  LCGuestExtensionPreparer.h
//  LiveContainer (fork)
//
//  Prepares apps' extensions (broadcast, share, action, keyboard, Safari content blocker, File Provider,
//  widgets, photo editing, iMessage, call directory, SMS filter) so LiveContainer's matching extensions can run them. Every app that has one is prepared
//  automatically; there is nothing to turn on. See LiveContainer/Tweaks/Fork/LCGuestExtension.h.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCGuestExtensionPreparer : NSObject
/// Extension points of the app's extensions that LiveContainer can run.
+ (NSArray<NSString *> *)supportedPointsInBundle:(NSString *)bundlePath;
+ (NSString *)displayNameForPoint:(NSString *)point;
/// Sensitive kinds (screen broadcast, keyboard, SMS filter) run only after you allow them per app.
+ (BOOL)isSensitivePoint:(NSString *)point;
+ (BOOL)isAllowedPoint:(NSString *)point folder:(NSString *)folder;
+ (void)setAllowed:(BOOL)allowed point:(NSString *)point folder:(NSString *)folder;
/// Converts the app's supported extension executables to signed dylibs and records them. Completion
/// is called on the main queue with nil on success.
+ (void)prepareBundle:(NSString *)bundlePath folder:(NSString *)folder isShared:(BOOL)isShared
           completion:(nullable void (^)(NSError *_Nullable error))completion;
/// Prepares every listed app (bundlePath, folder, isShared) that isn't prepared yet, and forgets apps
/// that are gone. Called at launch.
+ (void)syncApps:(NSArray<NSDictionary *> *)apps;
/// Forgets an app's prepared extensions (its prepared code goes away with its bundle).
+ (void)forgetFolder:(NSString *)folder;
/// The app was deleted: forgets it and its permissions.
+ (void)removeFolder:(NSString *)folder;
/// Whether this app's widgets are the ones LiveContainer shows.
+ (BOOL)isWidgetAppFolder:(NSString *)folder;
/// Shows this app's widgets (LiveContainer can show one app's widgets at a time).
+ (void)useWidgetsOfFolder:(NSString *)folder;
@end

NS_ASSUME_NONNULL_END
