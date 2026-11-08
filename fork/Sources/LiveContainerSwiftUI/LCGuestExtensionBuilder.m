//
//  LCGuestExtensionBuilder.m
//  LiveContainer (fork)
//

#import "LCGuestExtensionBuilder.h"
#import <CommonCrypto/CommonDigest.h>
#import <mach-o/loader.h>
#import "../../../LiveContainer/LCMachOUtils.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#import "../../../LiveContainerSwiftUI/Utilities/LCUtils.h"
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

/// What iOS shows for an app's extension copied into LiveContainer:
/// - kinds that work for one app at a time: LiveContainer's own name;
/// - others: "<App> - <Extension>", or just "<App>" when the extension has no name of its own.
static NSString *copyName(NSString *point, NSString *appName, NSString *extName, NSString *lcName) {
    if (LCGuestExtensionIsSingleApp(point)) return lcName;
    if (!extName.length || [extName caseInsensitiveCompare:appName] == NSOrderedSame) return appName;
    return [NSString stringWithFormat:@"%@ - %@", appName, extName];
}

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

/// 3.8.11.18-19 added apps' background modes and accessory protocols to LiveContainer's Info.plist
/// ("Background Events", since removed) and kept LiveContainer's own values under this key: put them
/// back. Remove in the next version.
static void restoreBackgroundEventsInfo(NSURL *app) {
    NSString *path = [app.path stringByAppendingPathComponent:@"Info.plist"];
    NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
    NSDictionary *originals = info[@"LCForkBackgroundOriginals"];
    if (!originals) return;
    for (NSString *key in originals) {
        if ([originals[key] isEqual:@"(absent)"]) [info removeObjectForKey:key];
        else info[key] = originals[key];
    }
    [info removeObjectForKey:@"LCForkBackgroundOriginals"];
    [info writeToFile:path atomically:YES];
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
            NSString *point = pointOf(appexes[appex]);
            if ([app[@"points"] containsObject:point]) [result addObject:@[app, appex, appexes[appex]]];
        }
    }
    [result sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) {
        return [[NSString stringWithFormat:@"%@/%@", a[0][@"folder"], a[1]] compare:[NSString stringWithFormat:@"%@/%@", b[0][@"folder"], b[1]]];
    }];
    return result;
}

+ (NSString *)signatureForApps:(NSArray<NSDictionary *> *)apps {
    NSArray *selected = [self selectedExtensions:apps];
    // Files needs one rebuild too: the File Provider's document group is set to LiveContainer's real
    // app group then (LCSelfIPABuilder).
    BOOL files = [[apps valueForKeyPath:@"@unionOfArrays.points"] containsObject:kLCPointFileProvider];
    if (!selected.count && !files) return @"";
    NSMutableString *text = [@"v5" mutableCopy];  // bump when copies are built differently, so installs rebuild
    if (files) [text appendString:@"|files"];
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
    NSString *hosted = [app.path stringByAppendingPathComponent:kLCHostedExtensionsFolder];
    [fm removeItemAtPath:hosted error:nil];
    restoreBackgroundEventsInfo(app);
    NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:[app.path stringByAppendingPathComponent:@"Info.plist"]];
    NSString *lcBundleId = NSBundle.mainBundle.bundleIdentifier;  // the rebuild fixes the prefix afterwards
    NSSet *singleDone = [NSMutableSet new];
    NSMutableArray<NSURL *> *toSign = [NSMutableArray new];  // hosted code, signed with LiveContainer's certificate

    for (NSArray *s in [self selectedExtensions:apps]) {
        NSDictionary *guest = s[0], *guestInfo = s[2];
        NSString *appexName = s[1], *point = pointOf(guestInfo);
        if (LCGuestExtensionIsSingleApp(point)) {
            if ([singleDone containsObject:point]) continue;  // iOS takes one per app
            [(NSMutableSet *)singleDone addObject:point];
        }
        NSString *src = [guest[@"bundlePath"] stringByAppendingFormat:@"/PlugIns/%@", appexName];
        NSString *hash = [sha256Hex([[NSString stringWithFormat:@"%@/%@", guest[@"folder"], appexName] dataUsingEncoding:NSUTF8StringEncoding]) substringToIndex:10];
        BOOL isHosted = LCGuestExtensionIsHosted(point);
        // Hosted copies aren't .appex, so neither iOS nor SideStore treats them as extensions.
        NSString *dst = isHosted ? [hosted stringByAppendingFormat:@"/LCX%@.lcext", hash] : [plugins stringByAppendingFormat:@"/LCX%@.appex", hash];
        [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        if (![fm copyItemAtPath:src toPath:dst error:error]) return NO;
        for (NSString *junk in @[@"_CodeSignature", @"embedded.mobileprovision", @"SC_Info", @"LCExtension.dylib", @"LCBroadcast.dylib"]) {
            [fm removeItemAtPath:[dst stringByAppendingPathComponent:junk] error:nil];
        }

        // Frameworks from the app that the extension uses, next to it (the extension looks in
        // @executable_path/Frameworks; @executable_path/../../Frameworks is LiveContainer's now).
        NSString *exec = [dst stringByAppendingPathComponent:guestInfo[@"CFBundleExecutable"]];
        NSMutableSet *frameworks = [NSMutableSet new];
        if (![self copyFrameworksFor:exec from:[guest[@"bundlePath"] stringByAppendingPathComponent:@"Frameworks"]
                                  to:[dst stringByAppendingPathComponent:@"Frameworks"] done:frameworks error:error]) return NO;

        if (isHosted) {
            // Not registered with iOS: LiveContainer's own extension loads this code as a library.
            NSString *dylib = [dst stringByAppendingPathComponent:kLCHostedDylibName];
            if (![fm moveItemAtPath:exec toPath:dylib error:error]) return NO;
            __block NSString *patchError = nil;
            NSString *parseError = LCParseMachO(dylib.fileSystemRepresentation, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
                if (LCIsMachOEncrypted(header)) { patchError = @"is encrypted"; return; }
                LCPatchExecSlice(path, header, false);
                const char *rpath = "@loader_path/Frameworks";
                if (!hasCommand(header, LC_RPATH, rpath)) {
                    if (headerRoom(header) < sizeof(struct rpath_command) + rnd8((uint32_t)strlen(rpath) + 1)) { patchError = @"has no room for a search path"; return; }
                    appendCommand(header, LC_RPATH, rpath);
                }
            });
            if (parseError || patchError) {
                if (error) *error = LCGEBError([NSString stringWithFormat:@"%@'s %@ %@.", guest[@"name"], appexName, patchError ?: parseError]);
                return NO;
            }
            [toSign addObject:[NSURL fileURLWithPath:dylib]];
            for (NSString *framework in frameworks) {
                NSString *fwPath = [dst stringByAppendingFormat:@"/Frameworks/%@", framework];
                NSString *binary = [framework hasSuffix:@".framework"] ? [fwPath stringByAppendingPathComponent:framework.stringByDeletingPathExtension] : fwPath;
                [toSign addObject:[NSURL fileURLWithPath:binary]];
            }
        }

        if (!isHosted) {
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

        }

        NSMutableDictionary *info = [guestInfo mutableCopy];
        NSString *appName = guest[@"name"] ?: @"App";
        NSString *lcName = lcInfo[@"CFBundleDisplayName"] ?: lcInfo[@"CFBundleName"] ?: @"LiveContainer";
        NSString *name = copyName(point, appName, guestInfo[@"CFBundleDisplayName"] ?: guestInfo[@"CFBundleName"], lcName);
        info[@"CFBundleDisplayName"] = name;
        info[@"CFBundleName"] = name;
        // Localized names would override the ones above; rename those too.
        for (NSString *lproj in [fm contentsOfDirectoryAtPath:dst error:nil]) {
            if (![lproj hasSuffix:@".lproj"]) continue;
            NSString *stringsPath = [dst stringByAppendingFormat:@"/%@/InfoPlist.strings", lproj];
            NSMutableDictionary *strings = [[NSDictionary dictionaryWithContentsOfFile:stringsPath] mutableCopy];
            if (!strings[@"CFBundleDisplayName"] && !strings[@"CFBundleName"]) continue;
            NSString *localized = copyName(point, appName, strings[@"CFBundleDisplayName"] ?: strings[@"CFBundleName"], lcName);
            strings[@"CFBundleDisplayName"] = localized;
            strings[@"CFBundleName"] = localized;
            [strings writeToFile:stringsPath atomically:YES];
        }
        // A File Provider keeps its documents in an app group it has: LiveContainer's.
        if (info[@"NSExtensionFileProviderDocumentGroup"] || [point isEqualToString:kLCPointFileProvider]) {
            info[@"NSExtensionFileProviderDocumentGroup"] = [LCSharedUtils appGroupID];
        }
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
    if (toSign.count) {
        // An extension of LiveContainer can only load code signed by the same team.
        if (!LCUtils.certificateData) {
            if (error) *error = LCGEBError(@"Apps' share extensions and File Providers need LiveContainer's signing certificate (JIT-less mode). Set it up in LiveContainer's settings.");
            return NO;
        }
        __block BOOL signedOK = NO;
        __block NSError *signError = nil;
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [LCUtils signFilesWithZSignWithURLs:toSign completionHandler:^(BOOL success, NSError *e) {
            signedOK = success;
            signError = e;
            dispatch_semaphore_signal(done);
        }];
        dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
        if (!signedOK) {
            if (error) *error = signError ?: LCGEBError(@"Signing apps' share extensions failed.");
            return NO;
        }
    }
    NSDictionary *state = @{@"signature": [self signatureForApps:apps]};
    return [state writeToURL:[app URLByAppendingPathComponent:kStateFile] error:error];
}

@end
