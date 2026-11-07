//
//  LCSelfIPABuilder.h
//  LiveContainer (fork)
//
//  Builds an IPA of the running LiveContainer so the built-in SideStore can reinstall it over itself
//  (used to add apps' Shortcuts actions and extensions without a Mac).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCSelfIPABuilder : NSObject

/// Copies LiveContainer.app into a work folder. Returns the copy, to change before signing.
+ (nullable NSURL *)copyBundleWithError:(NSError **)error;

/// Turns the copy's bundle IDs, app groups and application-identifier back into the form of the
/// original IPA (without the team ID suffix the installer added), so SideStore signs it to the same
/// App IDs as the current install, and ad-hoc signs every executable. Apps' extensions copied into
/// LiveContainer get only LiveContainer's app groups, so nothing new is registered with the Apple ID.
+ (BOOL)signBundle:(NSURL *)app error:(NSError **)error;

/// Zips the work folder's Payload into Documents/LCSelfUpdate/LiveContainer.ipa.
+ (nullable NSURL *)archivePreparedBundleWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
