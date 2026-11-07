//
//  LCFileProviderProxy.m
//  LiveContainer (fork)
//
//  File Provider "LiveContainer": locations that apps in LiveContainer add to the Files app
//  belong to LiveContainer; this runs the File Provider of the app that added each one.
//

@import FileProvider;
#import "../Common/LCExtensionProxy.h"

@interface LCFileProviderProxy : NSObject <NSFileProviderReplicatedExtension>
@end

@implementation LCFileProviderProxy

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
    NSString *error = nil;
    NSArray<NSDictionary *> *candidates = LCGuestExtensionCandidates(kLCPointFileProvider, &error);
    // Run the File Provider of the app that added this domain (recorded when it called addDomain).
    NSDictionary *entry = candidates.firstObject;
    NSString *owner = LCGuestExtensionFileProviderOwner(domain.identifier);
    for (NSDictionary *c in candidates) if ([c[kLCGEBundleId] isEqual:owner]) entry = c;
    Class cls = nil;
    if (entry && LCGuestExtensionLoad(entry, &error)) cls = NSClassFromString(entry[kLCGEPrincipalClass] ?: @"");
    if (cls && cls != self.class && [cls instancesRespondToSelector:@selector(initWithDomain:)]) {
        return [(id)[cls alloc] initWithDomain:domain];
    }
    NSLog(@"[LCGuestExtension] File Provider for %@: %@", domain.identifier, error);
    return [super init];
}

// Below: only reached when no app's File Provider could be loaded.
- (void)invalidate {}

static NSError *unavailable(void) {
    return [NSError errorWithDomain:NSFileProviderErrorDomain code:NSFileProviderErrorServerUnreachable userInfo:nil];
}

- (NSProgress *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier request:(NSFileProviderRequest *)request
                completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    completionHandler(nil, unavailable());
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)fetchContentsForItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier version:(NSFileProviderItemVersion *)requestedVersion
                                           request:(NSFileProviderRequest *)request
                                 completionHandler:(void (^)(NSURL * _Nullable, NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    completionHandler(nil, nil, unavailable());
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)createItemBasedOnTemplate:(NSFileProviderItem)itemTemplate fields:(NSFileProviderItemFields)fields contents:(NSURL *)url
                                  options:(NSFileProviderCreateItemOptions)options request:(NSFileProviderRequest *)request
                        completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    completionHandler(nil, 0, NO, unavailable());
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)modifyItem:(NSFileProviderItem)item baseVersion:(NSFileProviderItemVersion *)version changedFields:(NSFileProviderItemFields)changedFields
                  contents:(NSURL *)newContents options:(NSFileProviderModifyItemOptions)options request:(NSFileProviderRequest *)request
         completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    completionHandler(nil, 0, NO, unavailable());
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)identifier baseVersion:(NSFileProviderItemVersion *)version
                                 options:(NSFileProviderDeleteItemOptions)options request:(NSFileProviderRequest *)request
                       completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    completionHandler(unavailable());
    return [NSProgress progressWithTotalUnitCount:1];
}

- (id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier
                                                             request:(NSFileProviderRequest *)request error:(NSError **)error {
    if (error) *error = unavailable();
    return nil;
}

@end
