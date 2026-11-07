//
//  LCGuestExtension.m
//  LiveContainer (fork)
//

#import "LCGuestExtension.h"
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import "../../../LiveContainer/LCSharedUtils.h"
#import "../../../LiveContainer/Tweaks/Tweaks.h"

extern NSUserDefaults *lcUserDefaults;
extern NSUserDefaults *lcSharedDefaults;
extern NSString *lcAppGroupPath;
extern NSDictionary *guestAppInfo;
extern NSDictionary *guestContainerInfo;
extern NSString *lcGuestAppId;
extern bool isSharedBundle;
void overwriteMainNSBundle(NSBundle *newBundle);

static NSDictionary *loadedEntry;
static NSString *loadedDylibPath;

static void setUpDefaults(void) {
    if (lcSharedDefaults) return;
    NSString *groupId = [LCSharedUtils appGroupID];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:groupId];
    lcAppGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupId].path;
}

/// Folder holding Applications/ and Data/: the app group for shared apps, LiveContainer's Documents
/// otherwise (extensions can't see it directly; LiveContainer leaves a bookmark).
static NSString *rootFor(BOOL shared) {
    if (shared) return lcAppGroupPath ? [lcAppGroupPath stringByAppendingPathComponent:@"LiveContainer"] : nil;
    static NSString *privateRoot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSData *bookmark = [lcSharedDefaults dataForKey:@"LCLaunchExtensionPrivateDocBookmark"];
        BOOL stale = NO;
        NSURL *docs = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
        if (docs && [docs startAccessingSecurityScopedResource]) {
            privateRoot = docs.path;
            setenv("LC_HOME_PATH", docs.URLByDeletingLastPathComponent.path.fileSystemRepresentation, 1);
        }
    });
    return privateRoot;
}

BOOL LCGuestExtensionIsAllowed(NSUserDefaults *sharedDefaults, NSString *folder, NSString *point) {
    id value = [sharedDefaults dictionaryForKey:kLCGuestExtensionPermissionsKey][folder][point];
    return value ? [value boolValue] : !LCGuestExtensionIsSensitive(point);
}

NSArray<NSDictionary *> *LCGuestExtensionCandidates(NSString *point, NSString **error) {
    setUpDefaults();
    if (!lcAppGroupPath) {
        if (error) *error = @"LiveContainer has no app group. Reinstall it with its app group.";
        return @[];
    }
    NSDictionary *entries = [lcSharedDefaults dictionaryForKey:kLCGuestExtensionsKey][point];
    NSString *chosen = [lcSharedDefaults dictionaryForKey:kLCGuestExtensionChoiceKey][point];
    NSMutableArray<NSDictionary *> *found = [NSMutableArray new];
    BOOL unreachable = NO, notAllowed = NO;
    for (NSDictionary *entry in entries.allValues) {
        if (!LCGuestExtensionIsAllowed(lcSharedDefaults, entry[kLCGEFolder], point)) { notAllowed = YES; continue; }
        NSString *root = rootFor([entry[kLCGEIsShared] boolValue]);
        if (!root) { unreachable = YES; continue; }
        NSString *bundlePath = [root stringByAppendingFormat:@"/Applications/%@", entry[kLCGEFolder]];
        NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
        if (!appInfo) continue;
        NSMutableDictionary *resolved = [entry mutableCopy];
        resolved[@"bundlePath"] = bundlePath;
        resolved[@"root"] = root;
        id launched = appInfo[@"lastLaunched"];
        resolved[@"lastLaunched"] = [launched isKindOfClass:NSDate.class] ? launched : NSDate.distantPast;
        if ([entry[kLCGEFolder] isEqual:chosen]) resolved[@"chosen"] = @YES;
        [found addObject:resolved];
    }
    [found sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        if ([a[@"chosen"] boolValue] != [b[@"chosen"] boolValue]) return [a[@"chosen"] boolValue] ? NSOrderedAscending : NSOrderedDescending;
        return [b[@"lastLaunched"] compare:a[@"lastLaunched"]];
    }];
    if (!found.count && error) {
        *error = entries.count == 0
            ? @"None of your apps in LiveContainer has this kind of extension (or LiveContainer's JIT-less signing certificate isn't set up). Open LiveContainer once after installing one."
            : unreachable ? @"Can't reach LiveContainer's apps. Open LiveContainer once, then try again."
            : notAllowed ? [NSString stringWithFormat:@"No app is allowed to use %@. Allow it in the app's settings in LiveContainer.", LCGuestExtensionKindName(point)]
                          : @"The apps with this kind of extension are no longer installed in LiveContainer.";
    }
    return found;
}

BOOL LCGuestExtensionLoad(NSDictionary *entry, NSString **error) {
    if (loadedEntry) {
        if ([loadedEntry[kLCGEFolder] isEqual:entry[kLCGEFolder]]) return YES;
        if (error) *error = @"Another app's extension is already running here.";
        return NO;
    }
    setUpDefaults();
    NSString *bundlePath = entry[@"bundlePath"], *root = entry[@"root"];
    guestAppInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    if (!guestAppInfo || !info) {
        if (error) *error = [NSString stringWithFormat:@"%@ is no longer installed in LiveContainer.", entry[kLCGEName] ?: entry[kLCGEBundleId]];
        return NO;
    }

    // Same home and identity as when LiveContainer runs the app, so UserDefaults and app groups match.
    isSharedBundle = [entry[kLCGEIsShared] boolValue];
    lcGuestAppId = [guestAppInfo[@"doUseLCBundleId"] boolValue] ? guestAppInfo[@"LCOrignalBundleIdentifier"] : info[@"CFBundleIdentifier"];
    NSString *home = [root stringByAppendingFormat:@"/Data/Application/%@", guestAppInfo[@"LCDataUUID"]];
    setenv("CFFIXED_USER_HOME", home.fileSystemRepresentation, 1);
    setenv("HOME", home.fileSystemRepresentation, 1);
    setenv("TMPDIR", [home stringByAppendingPathComponent:@"tmp"].fileSystemRepresentation, 1);
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
    NUDGuestHooksInit();
    NSFMGuestHooksInit();

    NSString *appexPath = [bundlePath stringByAppendingFormat:@"/PlugIns/%@", entry[kLCGEAppex]];
    NSString *dylib = [appexPath stringByAppendingPathComponent:kLCGuestExtensionDylibName];
    if (!dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        if (error) *error = [NSString stringWithFormat:@"Couldn't load the app's extension code: %s. Open LiveContainer to prepare it again.", dlerror()];
        return NO;
    }
    loadedDylibPath = dylib;
    // The extension code finds its resources (storyboards, rule lists, assets) through Bundle.main.
    NSBundle *appexBundle = [NSBundle bundleWithPath:appexPath];
    if (appexBundle) overwriteMainNSBundle(appexBundle);
    loadedEntry = entry;
    NSLog(@"[LCGuestExtension] loaded %@ (%@)", entry[kLCGEBundleId], entry[kLCGEAppex]);
    return YES;
}

Class LCGuestExtensionLoadPrincipalClass(NSString *point, NSString **error) {
    NSDictionary *entry = LCGuestExtensionCandidates(point, error).firstObject;
    if (!entry || !LCGuestExtensionLoad(entry, error)) return nil;
    Class cls = NSClassFromString(entry[kLCGEPrincipalClass] ?: @"");
    if (!cls && error) *error = [NSString stringWithFormat:@"The app's extension class %@ wasn't found.", entry[kLCGEPrincipalClass]];
    return cls;
}

NSString *LCGuestExtensionFileProviderOwner(NSString *domainIdentifier) {
    setUpDefaults();
    return [lcSharedDefaults dictionaryForKey:kLCFileProviderDomainsKey][domainIdentifier];
}

NSDictionary *LCGuestExtensionLoadedEntry(void) {
    return loadedEntry;
}

int LCGuestExtensionRunMain(int argc, char **argv) {
    if (!loadedDylibPath) return -1;
    // dyld may report the path with /private in front, so match on the end of it.
    NSString *suffix = [NSString stringWithFormat:@"/%@/%@", loadedEntry[kLCGEAppex], kLCGuestExtensionDylibName];
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        if (![@(_dyld_get_image_name(i)) hasSuffix:suffix]) continue;
        const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(i);
        const uint8_t *cur = (const uint8_t *)(header + 1);
        for (uint32_t c = 0; c < header->ncmds; c++) {
            const struct load_command *lc = (const struct load_command *)cur;
            if (lc->cmd == LC_MAIN) {
                int (*entry)(int, char **, char **) = (void *)((uint8_t *)header + ((const struct entry_point_command *)lc)->entryoff);
                extern char **environ;
                return entry(argc, argv, environ);
            }
            cur += lc->cmdsize;
        }
    }
    return -1;
}
