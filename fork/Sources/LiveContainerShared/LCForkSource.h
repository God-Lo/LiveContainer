//
//  LCForkSource.h
//  LiveContainer (fork)
//
//  This fork's source (source.json), read the same way by LiveContainer's update check and the built-in
//  SideStore, so both always agree:
//  - Fetched through GitHub's API with the last ETag (an unchanged file costs nothing and isn't rate
//    limited); the plain link is the fallback.
//  - The last good copy is kept in the shared settings. A copy whose newest release is older than the
//    kept one (a stale cache) is ignored, so the newest release never goes backwards.
//  - LiveContainer's releases are sorted newest first by build number (3.8.11.10 > 3.8.11.9).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCForkSource : NSObject
@property (class, readonly) NSURL *sourceURL;
/// Header on the fork's own requests, so the SideStore hook passes them through.
@property (class, readonly) NSString *passthroughHeader;

/// Fetches the source. `data` is the source JSON with LiveContainer's releases sorted; on failure, the kept
/// copy if there is one. `error` is set only when there's nothing to return.
+ (void)fetchWithCompletion:(void (^)(NSData *_Nullable data, NSError *_Nullable error))completion;
/// The kept copy, if any.
+ (nullable NSData *)cachedData;

/// LiveContainer's newest release in source JSON: { build, notes, downloadURL }.
+ (nullable NSDictionary<NSString *, NSString *> *)latestReleaseIn:(NSData *)data;
/// This LiveContainer's build, e.g. "3.8.11.23".
+ (NSString *)installedBuild;
/// Compares builds part by part as numbers.
+ (NSComparisonResult)compareBuild:(NSString *)a to:(NSString *)b;
@end

NS_ASSUME_NONNULL_END
