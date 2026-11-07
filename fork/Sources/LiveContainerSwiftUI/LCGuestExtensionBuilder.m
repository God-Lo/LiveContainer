//
//  LCGuestExtensionBuilder.m
//  LiveContainer (fork)
//

#import "LCGuestExtensionBuilder.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/loader.h>
#import "../../../LiveContainer/LCMachOUtils.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#import "../LiveContainerShared/LCGuestExtension.h"

static NSString *const kStateFile = @"LCGuestExtensionsState.plist";
static const char *kRuntimePath = "@executable_path/../../Frameworks/LiveContainerShared.framework/LiveContainerShared";

static NSError *LCGEBError(NSString *message) {
    return [NSError errorWithDomain:@"LiveContainer.Extensions" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *sha256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static NSString *pointOf(NSDictionary *info) {
    return info[@"NSExtension"][@"NSExtensionPointIdentifier"] ?: info[@"EXAppExtensionAttributes"][@"EXExtensionPointIdentifier"];
}

static uint32_t rnd8(uint32_t v) { return (v + 7) & ~7u; }

/// Free bytes after the load commands, before the first section's contents.
static uint64_t headerRoom(struct mach_header_64 *header) {
    uint64_t first = UINT64_MAX;
    uint8_t *cur = (uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmd == LC_SEGMENT_64) {
            struct section_64 *sec = (struct section_64 *)((struct segment_command_64 *)lc + 1);
            for (uint32_t j = 0; j < ((struct segment_command_64 *)lc)->nsects; j++)
                if (sec[j].offset && sec[j].offset < first) first = sec[j].offset;
        }
        cur += lc->cmdsize;
    }
    uint64_t used = sizeof(struct mach_header_64) + header->sizeofcmds;
    return first == UINT64_MAX || first < used ? 0 : first - used;
}

static BOOL hasCommand(struct mach_header_64 *header, uint32_t cmd, const char *path) {
    uint8_t *cur = (uint8_t *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmd == cmd) {
            uint32_t off = cmd == LC_RPATH ? ((struct rpath_command *)lc)->path.offset : ((struct dylib_command *)lc)->dylib.name.offset;
            if (!strcmp((char *)lc + off, path)) return YES;
        }
        cur += lc->cmdsize;
    }
    return NO;
}

static void appendCommand(struct mach_header_64 *header, uint32_t cmd, const char *path) {
    uint8_t *at = (uint8_t *)(header + 1) + header->sizeofcmds;
    uint32_t base = cmd == LC_RPATH ? sizeof(struct rpath_command) : sizeof(struct dylib_command);
    uint32_t size = base + rnd8((uint32_t)strlen(path) + 1);
    memset(at, 0, size);
    if (cmd == LC_RPATH) {
        struct rpath_command *rp = (struct rpath_command *)at;
        rp->cmd = LC_RPATH; rp->cmdsize = size; rp->path.offset = base;
    } else {
        struct dylib_command *dl = (struct dylib_command *)at;
        dl->cmd = cmd; dl->cmdsize = size; dl->dylib.name.offset = base;
        dl->dylib.timestamp = 2; dl->dylib.current_version = 0x10000; dl->dylib.compatibility_version = 0x10000;
    }
    memcpy(at + base, path, strlen(path));
    header->ncmds++;
    header->sizeofcmds += size;
}

/// @rpath dependencies of a Mach-O, e.g. "Foo.framework/Foo".
static NSSet<NSString *> *rpathDependencies(NSString *path) {
    NSMutableSet *deps = [NSMutableSet new];
    LCParseMachO(path.fileSystemRepresentation, true, ^(const char *p, struct mach_header_64 *header, int fd, void *filePtr) {
        uint8_t *cur = (uint8_t *)(header + 1);
        for (uint32_t i = 0; i < header->ncmds; i++) {
            struct load_command *lc = (struct load_command *)cur;
            if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB || lc->cmd == LC_REEXPORT_DYLIB) {
                NSString *name = @((char *)lc + ((struct dylib_command *)lc)->dylib.name.offset);
                if ([name hasPrefix:@"@rpath/"]) [deps addObject:[name substringFromIndex:7]];
            }
            cur += lc->cmdsize;
        }
    });
    return deps;
}

@implementation LCGuestExtensionBuilder

+ (NSArray<NSString *> *)allPoints { return LCGuestExtensionPoints(); }
+ (NSString *)displayNameForPoint:(NSString *)point { return LCGuestExtensionKindName(point); }
+ (BOOL)isSingleAppPoint:(NSString *)point { return LCGuestExtensionIsSingleApp(point); }

/// appex folder name -> Info.plist, for the app's extensions LiveContainer can run.
+ (NSDictionary<NSString *, NSDictionary *> *)appexesInBundle:(NSString *)bundlePath {
    NSMutableDictionary *found = [NSMutableDictionary new];
    NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        if (![name hasSuffix:@".appex"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        if (info[@"CFBundleExecutable"] && [LCGuestExtensionPoints() containsObject:pointOf(info)]) found[name] = info;
    }
    return found;
}

+ (NSArray<NSString *> *)supportedPointsInBundle:(NSString *)bundlePath {
    NSMutableSet *points = [NSMutableSet new];
    for (NSDictionary *info in [self appexesInBundle:bundlePath].allValues) [points addObject:pointOf(info)];
    return [LCGuestExtensionPoints() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", points]];
}

/// (app, appex, info) for each extension the rebuild includes, sorted.
+ (NSArray<NSArray *> *)selectedExtensions:(NSArray<NSDictionary *> *)apps {
    NSMutableArray *result = [NSMutableArray new];
    for (NSDictionary *app in apps) {
        NSDictionary *appexes = [self appexesInBundle:app[@"bundlePath"]];
        for (NSString *appex in [appexes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if ([app[@"points"] containsObject:pointOf(appexes[appex])]) [result addObject:@[app, appex, appexes[appex]]];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[NSString stringWithFormat:@"%@/%@", a[0][@"folder"], a[1]] compare:[NSString stringWithFormat:@"%@/%@", b[0][@"folder"], b[1]]];
    }];
    return result;
}

+ (NSString *)signatureForApps:(NSArray<NSDictionary *> *)apps {
    NSArray *selected = [self selectedExtensions:apps];
    if (!selected.count) return @"";
    NSMutableString *text = [@"v1" mutableCopy];
    for (NSArray *s in selected) {
        NSDictionary *app = s[0];
        NSString *exec = [app[@"bundlePath"] stringByAppendingFormat:@"/PlugIns/%@/%@", s[1], s[2][@"CFBundleExecutable"]];
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:exec error:nil];
        [text appendFormat:@"|%@|%@|%@|%@|%@|%@", app[@"folder"], app[@"isShared"], app[@"name"], s[1],
                           attrs[NSFileSize], @([attrs.fileModificationDate timeIntervalSince1970])];
    }
    return sha256Hex([text dataUsingEncoding:NSUTF8StringEncoding]);
}

+ (NSString *)installedSignature {
    NSString *path = [NSBundle.mainBundle pathForResource:kStateFile.stringByDeletingPathExtension ofType:@"plist"];
    return [NSDictionary dictionaryWithContentsOfFile:path ?: @""][@"signature"] ?: @"";
}

+ (NSSet<NSString *> *)installedFolders {
    NSMutableSet *folders = [NSMutableSet new];
    NSString *plugins = NSBundle.mainBundle.builtInPlugInsPath;
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        NSString *folder = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]][kLCGuestExtensionInfoKey][kLCGEFolder];
        if (folder) [folders addObject:folder];
    }
    return folders;
}

/// Copies the app frameworks this binary needs (and theirs) into `frameworksDir`.
+ (BOOL)copyFrameworksFor:(NSString *)binary from:(NSString *)appFrameworks to:(NSString *)frameworksDir
                     done:(NSMutableSet *)done error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *dep in rpathDependencies(binary)) {
        NSString *top = dep.pathComponents.firstObject;  // Foo.framework or libFoo.dylib
        if ([done containsObject:top]) continue;
        NSString *src = [appFrameworks stringByAppendingPathComponent:top];
        if (![fm fileExistsAtPath:src]) continue;  // system or LiveContainer's own
        [done addObject:top];
        [fm createDirectoryAtPath:frameworksDir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *dst = [frameworksDir stringByAppendingPathComponent:top];
        if (![fm copyItemAtPath:src toPath:dst error:error]) return NO;
        NSString *depBinary = [frameworksDir stringByAppendingPathComponent:dep];
        if (![self copyFrameworksFor:depBinary from:appFrameworks to:frameworksDir done:done error:error]) return NO;
    }
    return YES;
}

+ (BOOL)addExtensionsOfApps:(NSArray<NSDictionary *> *)apps toApp:(NSURL *)app error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *plugins = [app.path stringByAppendingPathComponent:@"PlugIns"];
    // Start from LiveContainer's own extensions only.
    for (NSString *name in [fm contentsOfDirectoryAtPath:plugins error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        if (info[kLCGuestExtensionInfoKey]) [fm removeItemAtPath:[plugins stringByAppendingPathComponent:name] error:nil];
    }
    NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:[app.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *lcBundleId = NSBundle.mainBundle.bundleIdentifier;  // the rebuild fixes the prefix afterwards
    NSSet *singleDone = [NSMutableSet new];

    for (NSArray *s in [self selectedExtensions:apps]) {
        NSDictionary *guest = s[0], *guestInfo = s[2];
        NSString *appexName = s[1], *point = pointOf(guestInfo);
        if (LCGuestExtensionIsSingleApp(point)) {
            if ([singleDone containsObject:point]) continue;  // iOS takes one per app
            [(NSMutableSet *)singleDone addObject:point];
        }
        NSString *src = [guest[@"bundlePath"] stringByAppendingFormat:@"/PlugIns/%@", appexName];
        NSString *hash = [sha256Hex([[NSString stringWithFormat:@"%@/%@", guest[@"folder"], appexName] dataUsingEncoding:NSUTF8StringEncoding]) substringToIndex:10];
        NSString *dst = [plugins stringByAppendingFormat:@"/LCX%@.appex", hash];
        if (![fm copyItemAtPath:src toPath:dst error:error]) return NO;
        for (NSString *junk in @[@"_CodeSignature", @"embedded.mobileprovision", @"SC_Info", @"LCExtension.dylib", @"LCBroadcast.dylib"]) {
            [fm removeItemAtPath:[dst stringByAppendingPathComponent:junk] error:nil];
        }

        // Frameworks from the app that the extension uses, next to it (the extension looks in
        // @executable_path/Frameworks; @executable_path/../../Frameworks is LiveContainer's now).
        NSString *exec = [dst stringByAppendingPathComponent:guestInfo[@"CFBundleExecutable"]];
        if (![self copyFrameworksFor:exec from:[guest[@"bundlePath"] stringByAppendingPathComponent:@"Frameworks"]
                                  to:[dst stringByAppendingPathComponent:@"Frameworks"] done:[NSMutableSet new] error:error]) return NO;

        // Load LiveContainer's runtime first, so the app's environment is set up before its code runs.
        __block NSString *patchError = nil;
        NSString *parseError = LCParseMachO(exec.fileSystemRepresentation, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            if (LCIsMachOEncrypted(header)) { patchError = @"is encrypted"; return; }
            uint64_t need = 0;
            BOOL needRuntime = !hasCommand(header, LC_LOAD_DYLIB, kRuntimePath);
            BOOL needRPath = !hasCommand(header, LC_RPATH, "@executable_path/Frameworks");
            if (needRuntime) need += sizeof(struct dylib_command) + rnd8((uint32_t)strlen(kRuntimePath) + 1);
            if (needRPath) need += sizeof(struct rpath_command) + rnd8((uint32_t)strlen("@executable_path/Frameworks") + 1);
            if (headerRoom(header) < need) { patchError = @"has no room for LiveContainer's loader"; return; }
            if (needRPath) appendCommand(header, LC_RPATH, "@executable_path/Frameworks");
            if (needRuntime) appendCommand(header, LC_LOAD_DYLIB, kRuntimePath);
        });
        if (parseError || patchError) {
            if (error) *error = LCGEBError([NSString stringWithFormat:@"%@'s %@ %@.", guest[@"name"], appexName, patchError ?: parseError]);
            return NO;
        }

        NSMutableDictionary *info = [guestInfo mutableCopy];
        NSString *appName = guest[@"name"] ?: @"App";
        NSString *extName = guestInfo[@"CFBundleDisplayName"] ?: guestInfo[@"CFBundleName"] ?: appName;
        // Keep the app's name visible, as Shortcuts does: "<App> <Extension>" unless it already says it.
        info[@"CFBundleDisplayName"] = [extName.lowercaseString containsString:appName.lowercaseString] ? extName
                                       : [NSString stringWithFormat:@"%@ %@", appName, extName];
        info[@"CFBundleIdentifier"] = [NSString stringWithFormat:@"%@.lcx%@", lcBundleId, hash];
        info[@"CFBundleShortVersionString"] = lcInfo[@"CFBundleShortVersionString"];
        info[@"CFBundleVersion"] = lcInfo[@"CFBundleVersion"];
        info[kLCGuestExtensionInfoKey] = @{kLCGEFolder: guest[@"folder"], kLCGEIsShared: guest[@"isShared"] ?: @NO,
                                           kLCGEAppBundleId: guest[@"bundleId"] ?: @"", kLCGEAppName: appName,
                                           kLCGEAppexBundleId: guestInfo[@"CFBundleIdentifier"] ?: @""};
        if (![info writeToFile:[dst stringByAppendingPathComponent:@"Info.plist"] atomically:YES]) {
            if (error) *error = LCGEBError(@"Couldn't write an extension's Info.plist.");
            return NO;
        }
    }
    NSDictionary *state = @{@"signature": [self signatureForApps:apps]};
    return [state writeToURL:[app URLByAppendingPathComponent:kStateFile] error:error];
}

+ (void)removeLeftoversInApps:(NSArray<NSString *> *)bundlePaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *bundlePath in bundlePaths) {
        NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
        for (NSString *name in [fm contentsOfDirectoryAtPath:plugins error:nil]) {
            for (NSString *junk in @[@"LCExtension.dylib", @"LCBroadcast.dylib"]) {
                [fm removeItemAtPath:[plugins stringByAppendingFormat:@"/%@/%@", name, junk] error:nil];
            }
        }
    }
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    for (NSString *key in @[@"LCGuestExtensions", @"LCGuestExtensionChoice", @"LCGuestExtensionPermissions",
                            @"LCFileProviderDomains", @"LCBroadcastGuest", @"LCBroadcastGuests"]) {
        [shared removeObjectForKey:key];
    }
}

@end
