//
//  LCBroadcastPreparer.h
//  LiveContainer (fork)
//
//  Prepares guest apps' ReplayKit broadcast upload extensions so LiveBroadcastExtension can load them.
//  Every app that has one is prepared automatically; there is nothing to turn on. When a broadcast
//  starts, LiveBroadcastExtension runs the one from the app opened most recently.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCBroadcastPreparer : NSObject
/// The guest's broadcast upload extension (.appex folder name), or nil if it has none.
+ (nullable NSString *)broadcastAppexInBundle:(NSString *)bundlePath;
/// Converts the app's broadcast extension executable to a signed dylib and records the app. Does
/// nothing for apps without one. Completion is called on the main queue with nil on success.
+ (void)prepareBundle:(NSString *)bundlePath folder:(NSString *)folder isShared:(BOOL)isShared
           completion:(nullable void (^)(NSError *_Nullable error))completion;
/// Prepares every listed app (bundle path, folder, isShared) that isn't prepared yet, and forgets
/// apps that are gone. Called at launch.
+ (void)syncApps:(NSArray<NSDictionary *> *)apps;
/// Forgets an app (its prepared code goes away with its bundle).
+ (void)forgetFolder:(NSString *)folder;
@end

NS_ASSUME_NONNULL_END
