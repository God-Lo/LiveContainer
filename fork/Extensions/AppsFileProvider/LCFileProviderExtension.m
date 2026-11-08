//
//  LCFileProviderExtension.m
//  LiveContainer (fork)
//
//  LiveContainer's locations in the Files app: one per app that has Files turned on in its settings.
//  LiveContainer registers a domain per app ("lc.files.<app folder>") and keeps the list of apps in its
//  shared settings (LCForkFiles).
//
//  An app with its own File Provider runs it in its location: iOS allows one File Provider per app, so
//  the app's is kept inside LiveContainer (LCGuestExtensions) and loaded here, and it serves the location
//  as it would natively. Other apps' locations show their Documents folder, where files can be opened,
//  added, renamed, moved and deleted.
//
//  Item identifiers inside a location: the root container, and "f:<path>" for everything in it.
//

@import FileProvider;
@import UniformTypeIdentifiers;
#import "../../../LiveContainer/LCSharedUtils.h"
#import "../../Sources/LiveContainerShared/LCGuestExtension.h"

static NSString *const kAppsKey = @"LCFilesApps";  // [{ folder, name, isShared, dataUUID }]

static NSError *LCFPError(NSFileProviderErrorCode code) {
    return [NSError errorWithDomain:NSFileProviderErrorDomain code:code userInfo:nil];
}

#pragma mark - Status

/// What this location runs, for LiveContainer's settings: LiveContainer/FilesStatus/<folder>.txt in the
/// app group. A file, because an app's code changes UserDefaults in this process once it's loaded.
static NSString *statusFolder;

static void LCFPSetStatus(NSString *folder, NSString *status) {
    if (!statusFolder || !folder.length) return;
    [NSFileManager.defaultManager createDirectoryAtPath:statusFolder withIntermediateDirectories:YES attributes:nil error:nil];
    [status writeToFile:[statusFolder stringByAppendingFormat:@"/%@.txt", folder] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

#pragma mark - Paths

static NSString *const kDomainPrefix = @"lc.files.";

/// One app's Documents, for the location of that app.
@interface LCFPStore : NSObject
@property (nonatomic, copy) NSString *folder;
@property (nonatomic, copy) NSString *appName;
- (nullable NSString *)documents;
- (nullable NSString *)pathFor:(NSFileProviderItemIdentifier)identifier;
@end

@implementation LCFPStore

- (NSString *)documents {
    NSString *groupId = [LCSharedUtils appGroupID];
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:groupId];
    NSDictionary *app = nil;
    for (NSDictionary *a in [defaults arrayForKey:kAppsKey]) if ([a[@"folder"] isEqual:self.folder]) app = a;
    if (!app || ![app[@"dataUUID"] length]) return nil;
    self.appName = app[@"name"];
    NSString *root;
    if ([app[@"isShared"] boolValue]) {
        root = [[NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupId].path stringByAppendingPathComponent:@"LiveContainer"];
    } else {
        static NSString *privateRoot;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            NSData *bookmark = [defaults dataForKey:@"LCLaunchExtensionPrivateDocBookmark"];
            BOOL stale = NO;
            NSURL *docs = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
            if (docs && [docs startAccessingSecurityScopedResource]) privateRoot = docs.path;
        });
        root = privateRoot;
    }
    if (!root) return nil;
    NSString *docs = [root stringByAppendingFormat:@"/Data/Application/%@/Documents", app[@"dataUUID"]];
    [NSFileManager.defaultManager createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
    return docs;
}

- (NSString *)pathFor:(NSFileProviderItemIdentifier)identifier {
    NSString *docs = self.documents;
    if (!docs) return nil;
    if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) return docs;
    if (![identifier hasPrefix:@"f:"]) return nil;
    NSString *rel = [identifier substringFromIndex:2];
    if (!rel.length || [rel containsString:@".."]) return nil;
    return [docs stringByAppendingPathComponent:rel];
}

@end

#pragma mark - Items

@interface LCFPItem : NSObject <NSFileProviderItem>
@property (nonatomic, copy) NSFileProviderItemIdentifier itemIdentifier;
@property (nonatomic, copy) NSFileProviderItemIdentifier parentItemIdentifier;
@property (nonatomic, copy) NSString *filename;
@property (nonatomic) BOOL isFolder;
@property (nonatomic) BOOL isRoot;
@property (nonatomic, strong) NSNumber *documentSize;
@property (nonatomic, strong) NSDate *contentModificationDate;
@property (nonatomic, strong) NSDate *creationDate;
+ (nullable instancetype)itemFor:(NSFileProviderItemIdentifier)identifier store:(LCFPStore *)store;
@end

@implementation LCFPItem

+ (instancetype)itemFor:(NSFileProviderItemIdentifier)identifier store:(LCFPStore *)store {
    NSString *path = [store pathFor:identifier];
    NSDictionary *attrs = path ? [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] : nil;
    if (!attrs) return nil;
    LCFPItem *item = [LCFPItem new];
    item.itemIdentifier = identifier;
    item.isFolder = [attrs.fileType isEqualToString:NSFileTypeDirectory];
    item.documentSize = item.isFolder ? nil : @(attrs.fileSize);
    item.contentModificationDate = attrs.fileModificationDate;
    item.creationDate = attrs.fileCreationDate;
    if ([identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
        item.isRoot = YES;
        item.parentItemIdentifier = NSFileProviderRootContainerItemIdentifier;
        item.filename = store.appName ?: store.folder;
    } else {
        NSString *rel = [identifier substringFromIndex:2];
        NSString *parent = rel.stringByDeletingLastPathComponent;
        item.parentItemIdentifier = parent.length ? [@"f:" stringByAppendingString:parent] : NSFileProviderRootContainerItemIdentifier;
        item.filename = rel.lastPathComponent;
    }
    return item;
}

- (UTType *)contentType {
    if (self.isFolder) return UTTypeFolder;
    return [UTType typeWithFilenameExtension:self.filename.pathExtension] ?: UTTypeData;
}

- (NSFileProviderItemCapabilities)capabilities {
    if (self.isRoot)
        return NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsContentEnumerating | NSFileProviderItemCapabilitiesAllowsAddingSubItems;
    NSFileProviderItemCapabilities caps = NSFileProviderItemCapabilitiesAllowsReading | NSFileProviderItemCapabilitiesAllowsWriting |
        NSFileProviderItemCapabilitiesAllowsDeleting | NSFileProviderItemCapabilitiesAllowsRenaming | NSFileProviderItemCapabilitiesAllowsReparenting;
    if (self.isFolder) caps |= NSFileProviderItemCapabilitiesAllowsContentEnumerating | NSFileProviderItemCapabilitiesAllowsAddingSubItems;
    return caps;
}

- (NSFileProviderItemVersion *)itemVersion {
    NSString *v = [NSString stringWithFormat:@"%@-%f", self.documentSize ?: @0, self.contentModificationDate.timeIntervalSince1970];
    return [[NSFileProviderItemVersion alloc] initWithContentVersion:[v dataUsingEncoding:NSUTF8StringEncoding]
                                                     metadataVersion:[[self.filename ?: @"" stringByAppendingString:v] dataUsingEncoding:NSUTF8StringEncoding]];
}

@end

#pragma mark - Enumerator

@interface LCFPEnumerator : NSObject <NSFileProviderEnumerator>
@property (nonatomic, copy) NSFileProviderItemIdentifier container;
@property (nonatomic, strong) LCFPStore *store;
@end

@implementation LCFPEnumerator

- (void)invalidate {}

- (NSArray<LCFPItem *> *)items {
    NSMutableArray *items = [NSMutableArray new];
    if ([self.container isEqualToString:NSFileProviderWorkingSetContainerItemIdentifier]) return items;
    NSString *path = [self.store pathFor:self.container];
    NSString *prefix = [self.container isEqualToString:NSFileProviderRootContainerItemIdentifier] ? @"f:"
                                                                                                  : [self.container stringByAppendingString:@"/"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil]) {
        if ([name hasPrefix:@"."]) continue;
        LCFPItem *item = [LCFPItem itemFor:[prefix stringByAppendingString:name] store:self.store];
        if (item) [items addObject:item];
    }
    return items;
}

- (void)enumerateItemsForObserver:(id<NSFileProviderEnumerationObserver>)observer startingAtPage:(NSFileProviderPage)page {
    if (!self.store.documents) {
        LCFPSetStatus(self.store.folder, @"Can't reach the app's Documents");
        // Say so instead of looking empty.
        [observer finishEnumeratingWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoPermissionError userInfo:@{
            NSLocalizedDescriptionKey: @"LiveContainer's Files can't reach this app's Documents. Open LiveContainer once, then try again."}]];
        return;
    }
    [observer didEnumerateItems:self.items];
    [observer finishEnumeratingUpToPage:nil];
}

- (void)enumerateChangesForObserver:(id<NSFileProviderChangeObserver>)observer fromSyncAnchor:(NSFileProviderSyncAnchor)anchor {
    // Report the current contents; changes made inside the app show up the next time Files looks.
    NSArray *items = self.items;
    if (items.count) [observer didUpdateItems:items];
    [self currentSyncAnchorWithCompletionHandler:^(NSFileProviderSyncAnchor current) {
        [observer finishEnumeratingChangesUpToSyncAnchor:current moreComing:NO];
    }];
}

- (void)currentSyncAnchorWithCompletionHandler:(void (^)(NSFileProviderSyncAnchor))completionHandler {
    completionHandler([[NSString stringWithFormat:@"%f", NSDate.date.timeIntervalSince1970] dataUsingEncoding:NSUTF8StringEncoding]);
}

@end

#pragma mark - Extension

@interface LCFileProviderExtension : NSObject <NSFileProviderReplicatedExtension>
@end

@implementation LCFileProviderExtension {
    LCFPStore *_store;
}

- (instancetype)initWithDomain:(NSFileProviderDomain *)domain {
    NSString *identifier = domain.identifier;
    NSString *folder = [identifier hasPrefix:kDomainPrefix] ? [identifier substringFromIndex:kDomainPrefix.length] : identifier;
    // Before an app's code changes this process's environment.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]].path;
        statusFolder = group ? [group stringByAppendingPathComponent:@"LiveContainer/FilesStatus"] : nil;
    });
    id hosted = [LCFileProviderExtension appProviderFor:folder domain:domain];
    if (hosted) return hosted;
    self = [super init];
    _store = [LCFPStore new];
    _store.folder = folder;
    return self;
}

/// The app's own File Provider for this location, when it has one; iOS then talks to it directly.
+ (nullable id)appProviderFor:(NSString *)folder domain:(NSFileProviderDomain *)domain {
    for (NSDictionary *entry in LCHostedGuestExtensions(kLCPointFileProvider)) {
        if (![entry[kLCGuestExtensionInfoKey][kLCGEFolder] isEqual:folder]) continue;
        NSString *error = nil;
        if (!LCLoadHostedGuestExtensionCode(entry, &error)) {
            LCFPSetStatus(folder, [NSString stringWithFormat:@"Couldn't run the app's File Provider, showing its Documents: %@", error]);
            return nil;
        }
        NSString *className = entry[@"NSExtension"][@"NSExtensionPrincipalClass"] ?: @"";
        Class cls = NSClassFromString(className);
        if (![cls instancesRespondToSelector:@selector(initWithDomain:)]) {
            LCFPSetStatus(folder, [NSString stringWithFormat:@"The app's File Provider has no class %@, showing its Documents", className]);
            return nil;
        }
        LCFPSetStatus(folder, @"Running the app's File Provider");
        return [(id<NSFileProviderReplicatedExtension>)[cls alloc] initWithDomain:domain];
    }
    LCFPSetStatus(folder, @"Showing the app's Documents");
    return nil;
}

- (void)invalidate {}

- (NSProgress *)itemForIdentifier:(NSFileProviderItemIdentifier)identifier request:(NSFileProviderRequest *)request
                completionHandler:(void (^)(NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    LCFPItem *item = [LCFPItem itemFor:identifier store:_store];
    completionHandler(item, item ? nil : LCFPError(NSFileProviderErrorNoSuchItem));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)fetchContentsForItemWithIdentifier:(NSFileProviderItemIdentifier)itemIdentifier version:(NSFileProviderItemVersion *)requestedVersion
                                           request:(NSFileProviderRequest *)request
                                 completionHandler:(void (^)(NSURL * _Nullable, NSFileProviderItem _Nullable, NSError * _Nullable))completionHandler {
    NSString *path = [_store pathFor:itemIdentifier];
    LCFPItem *item = [LCFPItem itemFor:itemIdentifier store:_store];
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
static NSString *childPath(LCFPStore *store, NSFileProviderItemIdentifier parent, NSString *name, NSString **identifierOut) {
    NSString *dir = [store pathFor:parent];
    if (!dir || !name.length || [name containsString:@"/"]) return nil;
    if ([parent isEqualToString:NSFileProviderRootContainerItemIdentifier]) *identifierOut = [@"f:" stringByAppendingString:name];
    else if ([parent hasPrefix:@"f:"]) *identifierOut = [NSString stringWithFormat:@"%@/%@", parent, name];
    else return nil;
    return [dir stringByAppendingPathComponent:name];
}

- (NSProgress *)createItemBasedOnTemplate:(NSFileProviderItem)itemTemplate fields:(NSFileProviderItemFields)fields contents:(NSURL *)url
                                  options:(NSFileProviderCreateItemOptions)options request:(NSFileProviderRequest *)request
                        completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    NSString *identifier = nil;
    NSString *path = childPath(_store, itemTemplate.parentItemIdentifier, itemTemplate.filename, &identifier);
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
    LCFPItem *item = ok ? [LCFPItem itemFor:identifier store:_store] : nil;
    completionHandler(item, 0, NO, item ? nil : (error ?: LCFPError(NSFileProviderErrorNoSuchItem)));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)modifyItem:(NSFileProviderItem)item baseVersion:(NSFileProviderItemVersion *)version changedFields:(NSFileProviderItemFields)changedFields
                  contents:(NSURL *)newContents options:(NSFileProviderModifyItemOptions)options request:(NSFileProviderRequest *)request
         completionHandler:(void (^)(NSFileProviderItem _Nullable, NSFileProviderItemFields, BOOL, NSError * _Nullable))completionHandler {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *identifier = item.itemIdentifier;
    NSString *path = [_store pathFor:identifier];
    NSError *error = nil;
    if (!path || [identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) {
        completionHandler(nil, 0, NO, LCFPError(NSFileProviderErrorNoSuchItem));
        return [NSProgress progressWithTotalUnitCount:1];
    }
    if ((changedFields & NSFileProviderItemContents) && newContents) {
        [fm removeItemAtPath:path error:nil];
        [fm copyItemAtURL:newContents toURL:[NSURL fileURLWithPath:path] error:&error];
    }
    if (!error && (changedFields & (NSFileProviderItemFilename | NSFileProviderItemParentItemIdentifier))) {
        NSString *newId = nil;
        NSString *newPath = childPath(_store, item.parentItemIdentifier, item.filename, &newId);
        if (newPath && ![newPath isEqualToString:path] && [fm moveItemAtPath:path toPath:newPath error:&error]) identifier = newId;
    }
    LCFPItem *updated = error ? nil : [LCFPItem itemFor:identifier store:_store];
    completionHandler(updated, 0, NO, updated ? nil : (error ?: LCFPError(NSFileProviderErrorNoSuchItem)));
    return [NSProgress progressWithTotalUnitCount:1];
}

- (NSProgress *)deleteItemWithIdentifier:(NSFileProviderItemIdentifier)identifier baseVersion:(NSFileProviderItemVersion *)version
                                 options:(NSFileProviderDeleteItemOptions)options request:(NSFileProviderRequest *)request
                       completionHandler:(void (^)(NSError * _Nullable))completionHandler {
    NSString *path = [_store pathFor:identifier];
    NSError *error = nil;
    if (!path || [identifier isEqualToString:NSFileProviderRootContainerItemIdentifier]) error = LCFPError(NSFileProviderErrorNoSuchItem);
    else [NSFileManager.defaultManager removeItemAtPath:path error:&error];
    completionHandler(error);
    return [NSProgress progressWithTotalUnitCount:1];
}

- (id<NSFileProviderEnumerator>)enumeratorForContainerItemIdentifier:(NSFileProviderItemIdentifier)containerItemIdentifier
                                                             request:(NSFileProviderRequest *)request error:(NSError **)error {
    LCFPEnumerator *enumerator = [LCFPEnumerator new];
    enumerator.container = containerItemIdentifier;
    enumerator.store = _store;
    return enumerator;
}

@end
