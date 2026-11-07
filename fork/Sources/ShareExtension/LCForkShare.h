//
//  LCForkShare.h
//  LiveContainer (fork)
//
//  Apps' share extensions inside LiveContainer's own share item (see LCGuestExtension.h): iOS shows one
//  share item per app, so they're listed in LiveContainer's share menu under "Share With".
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCForkShare : NSObject
/// The apps' share extensions LiveContainer contains: [{ name, path, ... }].
+ (NSArray<NSDictionary *> *)entries;
/// Runs the app's share screen over `host`, with this share request. Returns NO with a reason on failure.
+ (BOOL)openEntry:(NSDictionary *)entry context:(nullable NSExtensionContext *)context
             from:(UIViewController *)host error:(NSString *_Nullable *_Nullable)error;
@end

NS_ASSUME_NONNULL_END
