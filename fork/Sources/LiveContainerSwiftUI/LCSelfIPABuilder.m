//
//  LCSelfIPABuilder.m
//  LiveContainer (fork)
//
//  Same approach as upstream's +[LCUtils archiveIPAWithBundleName:...] (which builds LiveContainer2),
//  but keeps the bundle identity, extensions and SideStore so the result is an update of this app.
//

#import "LCSelfIPABuilder.h"
#import <dlfcn.h>
#import "../../../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "../../../ZSign/zsigner.h"

@interface LCUtils (LCSelfIPABuilder)
+ (void)loadStoreFrameworksWithError2:(NSError **)error;
@end

static NSError *LCSIError(NSString *message) {
    return [NSError errorWithDomain:@"LiveContainer.SelfUpdate" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation LCSelfIPABuilder

+ (NSURL *)workURL {
    return [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:@"LCSelfUpdate"];
}

/// Rewrites one executable's entitlements for the original bundle ID and ad-hoc signs it.
+ (BOOL)fixEntitlementsOfExecutable:(NSURL *)exec installedPrefix:(NSString *)installedPrefix
                     originalPrefix:(NSString *)originalPrefix newBundleId:(NSString *)bundleId
                             teamId:(NSString *)teamId appGroupsOnly:(BOOL)appGroupsOnly error:(NSError **)error {
    NSString *xml = getExecutableEntitlementXML(exec.path);
    NSMutableDictionary *ent = xml ? [NSPropertyListSerialization propertyListWithData:[xml dataUsingEncoding:NSUTF8StringEncoding]
                                                                              options:NSPropertyListMutableContainers format:nil error:nil] : nil;
    if (![ent isKindOfClass:NSMutableDictionary.class]) ent = [NSMutableDictionary dictionary];
    if (appGroupsOnly) {
        // An app's extension copied into LiveContainer: whatever the app asked for, it only gets
        // LiveContainer's app groups, so SideStore registers nothing new.
        ent = [@{@"com.apple.security.application-groups": [@[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"] mutableCopy]} mutableCopy];
    }

    // SideStore appends the team ID to these groups when it signs, so give it the bare names.
    NSMutableArray *groups = ent[@"com.apple.security.application-groups"];
    if ([groups isKindOfClass:NSMutableArray.class]) {
        for (NSUInteger i = 0; i < groups.count; i++) {
            for (NSString *base in @[@"group.com.SideStore.SideStore", @"group.com.rileytestut.AltStore"]) {
                if ([groups[i] isEqualToString:[NSString stringWithFormat:@"%@.%@", base, teamId]]) groups[i] = base;
            }
        }
    }
    ent[@"application-identifier"] = [NSString stringWithFormat:@"%@.%@", teamId, bundleId];
    NSMutableArray *keychain = ent[@"keychain-access-groups"];
    if ([keychain isKindOfClass:NSMutableArray.class]) {
        for (NSUInteger i = 0; i < keychain.count; i++) {
            keychain[i] = [keychain[i] stringByReplacingOccurrencesOfString:installedPrefix withString:originalPrefix];
        }
    }
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:ent format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data) return NO;
    if (![NSClassFromString(@"ZSigner") adhocSignMachOAtPath:exec.path bundleId:bundleId entitlementData:data]) {
        if (error) *error = LCSIError([NSString stringWithFormat:@"Failed to sign %@", exec.lastPathComponent]);
        return NO;
    }
    return YES;
}

+ (NSURL *)copyBundleWithError:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSURL *work = self.workURL;
    [fm removeItemAtURL:work error:nil];
    NSURL *payload = [work URLByAppendingPathComponent:@"Payload"];
    if (![fm createDirectoryAtURL:payload withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSURL *app = [payload URLByAppendingPathComponent:@"LiveContainer.app"];
    if (![fm copyItemAtURL:NSBundle.mainBundle.bundleURL toURL:app error:error]) return nil;
    return app;
}

+ (BOOL)signBundle:(NSURL *)app error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *loadError = nil;
    [LCUtils loadStoreFrameworksWithError2:&loadError];
    if (loadError) { if (error) *error = loadError; return NO; }

    NSString *entXML = getExecutableEntitlementXML(NSBundle.mainBundle.executablePath);
    NSDictionary *mainEnt = entXML ? [NSPropertyListSerialization propertyListWithData:[entXML dataUsingEncoding:NSUTF8StringEncoding] options:0 format:nil error:nil] : nil;
    NSString *teamId = mainEnt[@"com.apple.developer.team-identifier"];
    if (![teamId isKindOfClass:NSString.class]) {
        if (error) *error = LCSIError(@"Could not read LiveContainer's team ID.");
        return NO;
    }

    NSString *installed = NSBundle.mainBundle.bundleIdentifier;
    NSString *suffix = [@"." stringByAppendingString:teamId];
    NSString *original = [installed hasSuffix:suffix] ? [installed substringToIndex:installed.length - suffix.length] : installed;

    // Main app plus every extension (PlugIns and ExtensionKit's Extensions).
    NSMutableArray<NSURL *> *bundles = [NSMutableArray arrayWithObject:app];
    for (NSString *dir in @[@"PlugIns", @"Extensions"]) {
        NSURL *parent = [app URLByAppendingPathComponent:dir];
        for (NSString *name in [fm contentsOfDirectoryAtPath:parent.path error:nil]) {
            if ([name hasSuffix:@".appex"]) [bundles addObject:[parent URLByAppendingPathComponent:name]];
        }
    }
    for (NSURL *bundle in bundles) {
        NSURL *infoURL = [bundle URLByAppendingPathComponent:@"Info.plist"];
        NSMutableDictionary *info = [NSMutableDictionary dictionaryWithContentsOfURL:infoURL];
        NSString *bid = info[@"CFBundleIdentifier"];
        if (!info || !bid) continue;
        if ([bid hasPrefix:installed]) {
            bid = [original stringByAppendingString:[bid substringFromIndex:installed.length]];
            info[@"CFBundleIdentifier"] = bid;
        }
        // A File Provider must name an app group it has: LiveContainer's actual one (with the team ID
        // SideStore adds, which an IPA built on a Mac can't know).
        if (info[@"NSExtension"][@"NSExtensionFileProviderDocumentGroup"]) {
            NSMutableDictionary *ext = [info[@"NSExtension"] mutableCopy];
            ext[@"NSExtensionFileProviderDocumentGroup"] = [NSClassFromString(@"LCSharedUtils") performSelector:@selector(appGroupID)];
            info[@"NSExtension"] = ext;
        }
        if (![info writeToURL:infoURL error:error]) return NO;
        NSURL *exec = [bundle URLByAppendingPathComponent:info[@"CFBundleExecutable"]];
        if (![self fixEntitlementsOfExecutable:exec installedPrefix:installed originalPrefix:original newBundleId:bid teamId:teamId
                                 appGroupsOnly:info[@"LCGuestExtension"] != nil error:error]) return NO;
    }
    return YES;
}

+ (NSURL *)archivePreparedBundleWithError:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    dlopen("/System/Library/PrivateFrameworks/PassKitCore.framework/PassKitCore", RTLD_GLOBAL);
    NSData *zip = [[NSClassFromString(@"PKZipArchiver") new] zippedDataForURL:self.workURL];
    if (!zip) {
        if (error) *error = LCSIError(@"Failed to create the IPA.");
        return nil;
    }
    NSURL *docs = [fm URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].lastObject;
    NSURL *outDir = [docs URLByAppendingPathComponent:@"LCSelfUpdate"];
    [fm createDirectoryAtURL:outDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSURL *ipa = [outDir URLByAppendingPathComponent:@"LiveContainer.ipa"];
    [fm removeItemAtURL:ipa error:nil];
    if (![zip writeToURL:ipa options:0 error:error]) return nil;
    [fm removeItemAtURL:self.workURL error:nil];
    return ipa;
}

@end
