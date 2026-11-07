//
//  LCGuestExtensionPreparer.m
//  LiveContainer (fork)
//

#import "LCGuestExtensionPreparer.h"
#import "../../../LiveContainerSwiftUI/Utilities/LCUtils.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#import "../LiveContainerShared/LCGuestExtension.h"
#import <UIKit/UIKit.h>
#import <mach-o/loader.h>

static NSError *LCGEError(NSString *message) {
    return [NSError errorWithDomain:@"LiveContainer.Extensions" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint32_t rnd8(uint32_t v) { return (v + 7) & ~7u; }

/// Lets the app's extension find the guest app's Frameworks from its own folder, as it would natively.
static void addFrameworksRPath(struct mach_header_64 *header) {
    const char *path = "@loader_path/../../Frameworks";
    uint8_t *cmds = (uint8_t *)header + sizeof(struct mach_header_64);
    uint8_t *cur = cmds;
    uint32_t textOff = 0;
    for (uint32_t i = 0; i < header->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmd == LC_RPATH && !strcmp((char *)lc + ((struct rpath_command *)lc)->path.offset, path)) return;
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((struct segment_command_64 *)lc)->segname, "__TEXT")) {
            struct section_64 *sec = (struct section_64 *)((struct segment_command_64 *)lc + 1);
            for (uint32_t j = 0; j < ((struct segment_command_64 *)lc)->nsects; j++)
                if (!strcmp(sec[j].sectname, "__text")) textOff = sec[j].offset;
        }
        cur += lc->cmdsize;
    }
    uint32_t size = (uint32_t)sizeof(struct rpath_command) + rnd8((uint32_t)strlen(path) + 1);
    if (textOff && (uint8_t *)header + textOff - cur < size) return;  // no room; frameworks may still resolve
    struct rpath_command *rp = (struct rpath_command *)cur;
    memset(rp, 0, size);
    rp->cmd = LC_RPATH;
    rp->cmdsize = size;
    rp->path.offset = sizeof(struct rpath_command);
    memcpy((uint8_t *)rp + rp->path.offset, path, strlen(path));
    header->ncmds++;
    header->sizeofcmds += size;
}

@implementation LCGuestExtensionPreparer

+ (NSUserDefaults *)shared {
    return [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
}


/// appex folder name -> its Info.plist, for each extension LiveContainer can run.
+ (NSDictionary<NSString *, NSDictionary *> *)supportedAppexInBundle:(NSString *)bundlePath {
    NSMutableDictionary *found = [NSMutableDictionary new];
    NSArray *points = LCGuestExtensionPoints();
    NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        if (![name hasSuffix:@".appex"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        NSDictionary *ext = info[@"NSExtension"];
        NSString *point = ext[@"NSExtensionPointIdentifier"];
        // Widget extensions may also declare it under EXAppExtensionAttributes.
        if (!point) point = info[@"EXAppExtensionAttributes"][@"EXExtensionPointIdentifier"];
        if ([points containsObject:point]) found[name] = info;
    }
    return found;
}

static NSString *pointOf(NSDictionary *info) {
    return info[@"NSExtension"][@"NSExtensionPointIdentifier"] ?: info[@"EXAppExtensionAttributes"][@"EXExtensionPointIdentifier"];
}

+ (NSArray<NSString *> *)supportedPointsInBundle:(NSString *)bundlePath {
    NSMutableSet *points = [NSMutableSet new];
    for (NSDictionary *info in [self supportedAppexInBundle:bundlePath].allValues) [points addObject:pointOf(info)];
    // In LiveContainer's order.
    return [LCGuestExtensionPoints() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF IN %@", points]];
}

+ (NSString *)displayNameForPoint:(NSString *)point { return LCGuestExtensionKindName(point); }
+ (BOOL)isSensitivePoint:(NSString *)point { return LCGuestExtensionIsSensitive(point); }
+ (BOOL)isAllowedPoint:(NSString *)point folder:(NSString *)folder { return LCGuestExtensionIsAllowed([self shared], folder, point); }

+ (void)setAllowed:(BOOL)allowed point:(NSString *)point folder:(NSString *)folder {
    NSUserDefaults *d = [self shared];
    NSMutableDictionary *all = [[d dictionaryForKey:kLCGuestExtensionPermissionsKey] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *app = [all[folder] mutableCopy] ?: [NSMutableDictionary new];
    app[point] = @(allowed);
    all[folder] = app;
    [d setObject:all forKey:kLCGuestExtensionPermissionsKey];
}

+ (void)setEntry:(nullable NSDictionary *)entry point:(NSString *)point folder:(NSString *)folder {
    NSUserDefaults *d = [self shared];
    NSMutableDictionary *all = [[d dictionaryForKey:kLCGuestExtensionsKey] mutableCopy] ?: [NSMutableDictionary new];
    NSMutableDictionary *forPoint = [all[point] mutableCopy] ?: [NSMutableDictionary new];
    forPoint[folder] = entry;
    all[point] = forPoint;
    [d setObject:all forKey:kLCGuestExtensionsKey];
}

+ (void)forgetFolder:(NSString *)folder {
    for (NSString *point in LCGuestExtensionPoints()) [self setEntry:nil point:point folder:folder];
    NSUserDefaults *d = [self shared];
    NSMutableDictionary *choice = [[d dictionaryForKey:kLCGuestExtensionChoiceKey] mutableCopy];
    for (NSString *point in choice.allKeys) if ([choice[point] isEqual:folder]) [choice removeObjectForKey:point];
    if (choice) [d setObject:choice forKey:kLCGuestExtensionChoiceKey];
}

/// The app was deleted: also drop what was recorded for it.
+ (void)removeFolder:(NSString *)folder {
    [self forgetFolder:folder];
    NSUserDefaults *d = [self shared];
    NSMutableDictionary *perms = [[d dictionaryForKey:kLCGuestExtensionPermissionsKey] mutableCopy];
    [perms removeObjectForKey:folder];
    if (perms) [d setObject:perms forKey:kLCGuestExtensionPermissionsKey];
}

+ (void)prepareBundle:(NSString *)bundlePath folder:(NSString *)folder isShared:(BOOL)isShared
           completion:(void (^)(NSError *))completion {
    void (^done)(NSError *) = ^(NSError *e) {
        if (e) NSLog(@"[LCGuestExtension] couldn't prepare %@: %@", folder, e.localizedDescription);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
    };
    if (!folder.length) return done(nil);
    [self forgetFolder:folder];
    NSDictionary<NSString *, NSDictionary *> *appexes = [self supportedAppexInBundle:bundlePath];
    if (!appexes.count) return done(nil);
    if (!LCUtils.certificateData) {
        return done(LCGEError(@"Running apps' extensions needs LiveContainer's signing certificate (JIT-less mode)."));
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary *bundleInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *appName = bundleInfo[@"CFBundleDisplayName"] ?: bundleInfo[@"CFBundleName"] ?: bundleInfo[@"CFBundleIdentifier"];
    NSMutableArray<NSURL *> *dylibs = [NSMutableArray new];
    NSMutableArray<NSArray *> *entries = [NSMutableArray new];  // [point, entry]
    NSString *firstError = nil;
    for (NSString *appex in appexes) {
        NSDictionary *info = appexes[appex];
        NSString *point = pointOf(info);
        NSString *exec = info[@"CFBundleExecutable"];
        NSString *principal = info[@"NSExtension"][@"NSExtensionPrincipalClass"];
        NSString *storyboard = info[@"NSExtension"][@"NSExtensionMainStoryboard"];
        if (!exec || (!principal && !storyboard && ![point isEqual:kLCPointWidgets])) continue;
        NSString *appexPath = [bundlePath stringByAppendingFormat:@"/PlugIns/%@", appex];
        NSString *dylib = [appexPath stringByAppendingPathComponent:kLCGuestExtensionDylibName];
        [fm removeItemAtPath:dylib error:nil];
        [fm removeItemAtPath:[appexPath stringByAppendingPathComponent:@"LCBroadcast.dylib"] error:nil];  // older builds
        NSError *error = nil;
        if (![fm copyItemAtPath:[appexPath stringByAppendingPathComponent:exec] toPath:dylib error:&error]) {
            firstError = firstError ?: error.localizedDescription;
            continue;
        }
        NSString *patchError = LCParseMachO(dylib.fileSystemRepresentation, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
            LCPatchExecSlice(path, header, false);
            addFrameworksRPath(header);
        });
        if (patchError) { [fm removeItemAtPath:dylib error:nil]; firstError = firstError ?: patchError; continue; }
        [dylibs addObject:[NSURL fileURLWithPath:dylib]];
        NSMutableDictionary *entry = [@{kLCGEBundleId: bundleInfo[@"CFBundleIdentifier"] ?: @"", kLCGEName: appName ?: @"",
                                        kLCGEFolder: folder, kLCGEIsShared: @(isShared), kLCGEAppex: appex} mutableCopy];
        entry[kLCGEPrincipalClass] = principal;
        entry[kLCGEStoryboard] = storyboard;
        [entries addObject:@[point, entry]];
    }
    if (!dylibs.count) return done(firstError ? LCGEError(firstError) : nil);

    [LCUtils signFilesWithZSignWithURLs:dylibs completionHandler:^(BOOL success, NSError *signError) {
        if (!success) {
            for (NSURL *url in dylibs) [fm removeItemAtURL:url error:nil];
            return done(signError ?: LCGEError(@"Signing the apps' extension code failed."));
        }
        for (NSArray *pair in entries) [self setEntry:pair[1] point:pair[0] folder:folder];
        done(firstError ? LCGEError(firstError) : nil);
    }];
}

+ (void)syncApps:(NSArray<NSDictionary *> *)apps {
    NSUserDefaults *d = [self shared];
    // Builds before this kept broadcast apps under their own keys.
    [d removeObjectForKey:@"LCBroadcastGuest"];
    [d removeObjectForKey:@"LCBroadcastGuests"];
    NSDictionary *all = [d dictionaryForKey:kLCGuestExtensionsKey];
    NSMutableSet<NSString *> *known = [NSMutableSet new];
    for (NSDictionary *forPoint in all.allValues) [known addObjectsFromArray:forPoint.allKeys];

    NSMutableArray<NSDictionary *> *todo = [NSMutableArray new];
    NSMutableSet<NSString *> *present = [NSMutableSet new];
    for (NSDictionary *app in apps) {
        NSString *path = app[@"bundlePath"], *folder = app[@"folder"];
        if (!path.length || !folder.length) continue;
        NSDictionary *appexes = [self supportedAppexInBundle:path];
        if (!appexes.count) continue;
        [present addObject:folder];
        BOOL ready = [known containsObject:folder];
        for (NSString *appex in appexes) {
            if (![NSFileManager.defaultManager fileExistsAtPath:[path stringByAppendingFormat:@"/PlugIns/%@/%@", appex, kLCGuestExtensionDylibName]]) ready = NO;
        }
        if (!ready) [todo addObject:app];
    }
    for (NSString *folder in known) {
        if (![present containsObject:folder]) [self forgetFolder:folder];
    }
    [self prepareNext:todo];
}

+ (void)prepareNext:(NSMutableArray<NSDictionary *> *)todo {
    if (!todo.count) return;
    NSDictionary *app = todo.firstObject;
    [todo removeObjectAtIndex:0];
    [self prepareBundle:app[@"bundlePath"] folder:app[@"folder"] isShared:[app[@"isShared"] boolValue]
             completion:^(NSError *e) { [self prepareNext:todo]; }];
}

+ (BOOL)isWidgetAppFolder:(NSString *)folder {
    return [[[self shared] dictionaryForKey:kLCGuestExtensionChoiceKey][kLCPointWidgets] isEqual:folder];
}

+ (void)useWidgetsOfFolder:(NSString *)folder {
    NSUserDefaults *d = [self shared];
    NSMutableDictionary *choice = [[d dictionaryForKey:kLCGuestExtensionChoiceKey] mutableCopy] ?: [NSMutableDictionary new];
    choice[kLCPointWidgets] = folder;
    [d setObject:choice forKey:kLCGuestExtensionChoiceKey];
}

@end
