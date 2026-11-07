//
//  LCSelfIPABuilder.h
//  LiveContainer (fork)
//
//  Builds an IPA of the running LiveContainer so the built-in SideStore can reinstall it over itself
//  (used to register new guest Shortcuts actions without a Mac).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCSelfIPABuilder : NSObject

/// Copies LiveContainer.app into a work folder and turns the bundle IDs, app groups and
/// application-identifier back into the form of the original IPA (without the team ID suffix the
/// installer added), so SideStore signs it to the same App IDs as the current install.
/// Returns the copied LiveContainer.app.
+ (nullable NSURL *)prepareBundleWithError:(NSError **)error;

/// Zips the work folder's Payload into Documents/LCSelfUpdate/LiveContainer.ipa.
+ (nullable NSURL *)archivePreparedBundleWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
