//
//  LCFileProviderExtension.m
//  LiveContainer (fork)
//
//  LiveContainer's location in the Files app: one folder per app that has Files turned on in its
//  settings, showing that app's Documents folder. Files can be opened, added, renamed, moved and
//  deleted. LiveContainer keeps the list of apps in its shared settings (LCForkFiles) and the location
//  itself registered while any app uses it.
//
//  Item identifiers: "a:<app folder>" for an app's folder, "f:<app folder>/<path>" inside it.
//

@import FileProvider;
@import UniformTypeIdentifiers;
#import "../../../LiveContainer/LCSharedUtils.h"

static NSString *const kAppsKey = @"LCFilesApps";  // [{ folder, name, isShared, dataUUID }]

static NSError *LCFPError(NSFileProviderErrorCode code) {
    return [NSError errorWithDomain:NSFileProviderErrorDomain code:code userInfo:nil];
}

#pragma mark - Paths

@interface LCFPStore : NSObject
@property (nonatomic, readonly) NSArray<NSDictionary *> *apps;
+ (instancetype)shared;
- (nullable NSString *)documentsOfApp:(NSString *)folder;
- (nullable NSString *)pathFor:(NSFileProviderItemIdentifier)identifier;
@end

@implementation LCFPStore {
    NSString *_groupPath;
    NSString *_privateRoot;
    NSUserDefaults *_defaults;
}

+ (instancetype)shared {
    static LCFPStore *store;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ store = [LCFPStore new]; });
    return store;
}

- (instancetype)init {
    self = [super init];
    NSString *groupId = [LCSharedUtils appGroupID];
    _defaults = [[NSUserDefaults alloc] initWithSuiteName:groupId];
    _groupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupId].path;
    NSData *bookmark = [_defaults dataForKey:@"LCLaunchExtensionPrivateDocBookmark"];
    BOOL stale = NO;
    NSURL *docs = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
    if (docs && [docs startAccessingSecurityScopedResource]) _privateRoot = docs.path;
    return self;
}

- (NSArray<NSDictionary *> *)apps {
    return [_defaults arrayForKey:kAppsKey] ?: @[];
}

- (NSDictionary *)app:(NSString *)folder {
    for (NSDictionary *app in self.apps) if ([app[@"folder"] isEqual:folder]) return app;
    return nil;
}

- (NSString *)documentsOfApp:(NSString *)folder {
    NSDictionary *app = [self app:folder];
    NSString *root = [app[@"isShared"] boolValue] ? [_groupPath stringByAppendingPathComponent:@"LiveContainer"] : _privateRoot;
    if (!app || !root || ![app[@"dataUUID"] length]) return nil;
    NSString *docs = [root stringByAppendingFormat:@"/Data/Application/%@/Documents", app[@"dataUUID"]];
    [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
    return docs;
}

- (NSString *)pathFor:(NSFileProviderItemIdentifier)identifier {
    if ([identifier hasPrefix:@"a:"]) return [self documentsOfApp:[identifier substringFromIndex:2]];
    if (![identifier hasPrefix:@"f:"]) return nil;
    NSString *rest = [identifier substringFromIndex:2];
    NSRange slash = [rest rangeOfString:@"/"];
    if (slash.location == NSNotFound) return nil;
    NSString *docs = [self documentsOfApp:[rest substringToIndex:slash.location]];
    NSString *rel = [rest substringFromIndex:slash.location + 1];
    if (!docs || [rel containsString:@".."]) return nil;
    return [docs stringByAppendingPathComponent:rel];
}

@end

#pragma mark - Items

@interface LCFPItem : NSObject <NSFileProviderItem>
@property (nonatomic, copy) NSFileProviderItemIdentifier itemIdentifier;
@property (nonatomic, copy) NSFileProviderItemIdentifier parentItemIdentifier;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic) BOOL isFolder;
@property (nonatomic) BOOL isAppFolder;
@property (nonatomic, strong) NSNumber *documentSize;
@property (nonatomic, strong) NSDate *contentModificationDate;
@property (nonatomic, strong) NSDate *creationDate;
+ (nullable instancetype)itemFor:(NSFileProviderItemIdentifier)identifier;
@end

@implementation LCFPItem

+ (instancetype)itemFor:(NSFileProviderItemIdentifier)identifier {
    LCFPItem *item = [LCFPItem new];
    item.itemIdentifier = identifier;
    if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
        item.parentItemIdentifier = NSFileProviderRootContainerItemIdentifier;
        item.filename = @"LiveContainer";
        item.isFolder = YES;
        return item;
    }
    NSString *path = [LCFPStore.shared pathFor:identifier];
    NSDictionary *attrs = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
    if (!attrs) return nil;
    item.isFolder = [attrs.fileType isEqualToString:NSFileTypeDirectory];
    item.documentSize = item.isFolder ? nil : @(attrs.fileSize);
    item.contentModificationDate = attrs.fileModificationDate;
    item.creationDate = attrs.fileCreationDate;
    if ([identifier hasPrefix:@"a:"]) {
        NSString *folder = [identifier substringFromIndex:2];
        item.isAppFolder = YES;
        item.parentItemIdentifier = NSFileProviderRootContainerItemIdentifier;
        for (NSDictionary *app in LCFPStore.shared.apps) if ([app[@"folder"] isEqual:folder]) item.filename = app[@"name"];
        item.filename = item.filename ?: folder;
    } else {
        NSString *rest = [identifier substringFromIndex:2];
        NSString *parent = rest.stringByDeletingLastPathComponent;
        item.parentItemIdentifier = [parent containsString:@"/"] ? [@"f:" stringByAppendingString:parent] : [@"a:" stringByAppendingString:parent];
        item.filename = rest.lastPathComponent;
    }
    return item;
}

- (UTType *)contentType {
    if (self.isFolder) return UTTypeFolder;
    return [UTType typeWithFilenameExtension:self.filename.pathExtension] ?: UTTypeData;
}

- (NSFileProviderItemCapabilities)capabilities {
    if ([self.itemIdentifier isEqualToString:NSFileProviderRootContainerItemIdentifier])
        return NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsContentEnumerating;
    if (self.isAppFolder)
        return NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsContentEnumerating | NSFileProviderItemCapabilitiesAllowsAddingSubItems;
    NSFileProviderItemCapabilities caps = NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsWriting |
        NSFileProviderItemCapabilitiesAllowsDeleting | NSFileProviderItemCapabilitiesAllowsRenaming | NSFileProviderItemCapabilitiesAllowsReparenting;
    if (self.isFolder) caps |= NSFileProviderItemCapabilitiesAllowsContentEnumerating | NSFileProviderItemCapabilitiesAllowsAddingSubItems;
    return caps;
}

- (NSFileProviderItemVersion *)itemVersion {
    NSString *v = [NSString stringWithFormat:@"%@-%f", self.documentSize ?: @0, self.contentModificationDate.timeIntervalSince1970];
    NSData *data = [v dataUsingEncoding:NSUTF8StringEncoding];
    return [[NSFileProviderItemVersion alloc] initWithContentVersion:data metadataVersion:[[self.filename ?: @"" stringByAppendingString:v] dataUsingEncoding:NSUTF8StringEncoding]];
}

@end

#pragma mark - Enumerator

@interface LCFPEnumerator : NSObject <NSFileProviderEnumerator>
@property (nonatomic, copy) NSFileProviderItemIdentifier container;
@end

@implementation LCFPEnumerator

- (void)invalidate {}

- (NSArray<LCFPItem *> *)items {
    NSMutableArray *items = [NSMutableArray new];
    if ([self.container isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
        for (NSDictionary *app in LCFPStore.shared.apps) {
            LCFPItem *item = [LCFPItem itemFor:[@"a:" stringByAppendingString:app[@"folder"]]];
            if (item) [items addObject:item];
        }
        return items;
    }
    if ([self.container isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) return items;
    NSString *path = [LCFPStore.shared pathFor:self.container];
    NSString *prefix = [self.container hasPrefix:@"a:"] ? [NSString stringWithFormat:@"f:%@/", [self.container substringFromIndex:2]]
                                                         : [[self.container stringByAppendingString:@"/"] copy];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        LCFPItem *item = [LCFPItem itemFor:[prefix stringByAppendingString:name]];
        if (item) [items addObject:item];
    }
    return items;
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer startingAtPage:(NSFileProviderPage)page {
    [observer didEnumerateItems:self.items];
    [observer finishEnumeratingUpToPage:nil];
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer fromSyncAnchor:(NSFileProviderSyncAnchor)anchor {
    // Report the current contents; changes made inside the apps show up the next time Files looks.
    NSArray *items = self.items;
    if (items.count) [observer didUpdateItems:items];
    [self currentSyncAnchorWithCompletionHandler:^(NSFileProviderSyncAnchor current) {
        [observer finishEnumeratingChangesUpToSyncAnchor:current moreComing:NO];
    }];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor))completionHandler {
    NSString *now = [NSString stringWithFormat:@"%f", NSDate.date.timeIntervalSince1970];
    completionHandler([now dataUsingEncoding:NSUTF8StringEncoding]);
}

@end

#pragma mark - Extension

@interface LCFileProviderExtension : NSObject <NSFileProviderReplicatedExtension>
@end

@implementation LCFileProviderExtension

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
    return [super init];
}

- (void)invalidate {}

- (NSProgress *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier request:(NSFileProviderRequest *)request
                completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    LCFPItem *item = [LCFPItem itemFor:identifier];
    completionHandler(item, item ? nil : LCFPError(NSFileProviderErrorNoSuchItem));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)fetchContentsForItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier version:(NSFileProviderItemVersion *)requestedVersion
                                           request:(NSFileProviderRequest *)request
                                 completionHandler:(void (^)(NSURL * _Nullable, NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    NSString *path = [LCFPStore.shared pathFor:itemIdentifier];
    LCFPItem *item = [LCFPItem itemFor:itemIdentifier];
    if (!path || !item) {
        completionHandler(nil, nil, LCFPError(NSFileProviderErrorNoSuchItem));
        return [NSProgress progressWithTotalUnitCount:1];
    }
    // Hand Files a copy; it moves the file it's given.
    NSURL *copy = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:[NSURL fileURLWithPath:path] toURL:copy error:&error]) {
        completionHandler(nil, nil, error);
    } else {
        completionHandler(copy, item, nil);
    }
    return [NSProgress progressWithTotalUnitCount:1];
}

/// Path for a new item named `name` in container `parent`, and its identifier.
static NSString *childPath(NSFileProviderItemIdentifier parent, NSString *name, NSString **identifierOut) {
    NSString *dir = [LCFPStore.shared pathFor:parent];
    if (!dir || !name.length || [name containsString:@"/"]) return nil;
    if ([parent hasPrefix:@"a:"]) *identifierOut = [NSString stringWithFormat:@"f:%@/%@", [parent substringFromIndex:2], name];
    else if ([parent hasPrefix:@"f:"]) *identifierOut = [NSString stringWithFormat:@"%@/%@", parent, name];
    else return nil;
    return [dir stringByAppendingPathComponent:name];
}

- (NSProgress *)createItemBasedOnTemplate:(NSFileProviderItem)itemTemplate fields:(NSFileProviderItemFields)fields contents:(NSURL *)url
                                  options:(NSFileProviderCreateItemOptions)options request:(NSFileProviderRequest *)request
                        completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    NSString *identifier = nil;
    NSString *path = childPath(itemTemplate.parentItemIdentifier, itemTemplate.filename, &identifier);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *error = nil;
    BOOL ok = NO;
    if (path) {
        if ([itemTemplate.contentType conformsToType:UTTypeFolder]) {
            ok = [fm createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:&error];
        } else {
            [fm removeItemAtPath:path error:nil];
            ok = url ? [fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:path] error:&error] : [fm createFileAtPath:path contents:NSData.data attributes:nil];
        }
    }
    LCFPItem *item = ok ? [LCFPItem itemFor:identifier] : nil;
    completionHandler(item, 0, NO, item ? nil : (error ?: LCFPError(NSFileProviderErrorNoSuchItem)));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)modifyItem:(NSFileProviderItem)item baseVersion:(NSFileProviderItemVersion *)version changedFields:(NSFileProviderItemFields)changedFields
                  contents:(NSURL *)newContents options:(NSFileProviderModifyItemOptions)options request:(NSFileProviderRequest *)request
         completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *identifier = item.itemIdentifier;
    NSString *path = [LCFPStore.shared pathFor:identifier];
    NSError *error = nil;
    if (!path || [identifier hasPrefix:@"a:"]) {
        completionHandler(nil, 0, NO, LCFPError(NSFileProviderErrorNoSuchItem));
        return [NSProgress progressWithTotalUnitCount:1];
    }
    if ((changedFields & NSFileProviderItemContents) && newContents) {
        [fm removeItemAtPath:path error:nil];
        [fm copyItemAtURL:newContents toURL:[NSURL fileURLWithPath:path] error:&error];
    }
    if (!error && (changedFields & (NSFileProviderItemFilename | NSFileProviderItemParentItemIdentifier))) {
        NSString *newId = nil;
        NSString *newPath = childPath(item.parentItemIdentifier, item.filename, &newId);
        if (newPath && ![newPath isEqualToString:path] && [fm moveItemAtPath:path toPath:newPath error:&error]) identifier = newId;
    }
    LCFPItem *updated = error ? nil : [LCFPItem itemFor:identifier];
    completionHandler(updated, 0, NO, updated ? nil : (error ?: LCFPError(NSFileProviderErrorNoSuchItem)));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)identifier baseVersion:(NSFileProviderItemVersion *)version
                                 options:(NSFileProviderDeleteItemOptions)options request:(NSFileProviderRequest *)request
                       completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    NSString *path = [LCFPStore.shared pathFor:identifier];
    NSError *error = nil;
    if (!path || [identifier hasPrefix:@"a:"]) error = LCFPError(NSFileProviderErrorNoSuchItem);
    else [NSFileManager.defaultManager removeItemAtPath:path error:&error];
    completionHandler(error);
    return [NSProgress progressWithTotalUnitCount:1];
}

- (id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier
                                                             request:(NSFileProviderRequest *)request error:(NSError **)error {
    LCFPEnumerator *enumerator = [LCFPEnumerator new];
    enumerator.container = containerItemIdentifier;
    return enumerator;
}

@end
