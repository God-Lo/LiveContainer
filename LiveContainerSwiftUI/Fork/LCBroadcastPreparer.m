//
//  LCBroadcastPreparer.m
//  LiveContainer (fork)
//

#import "LCBroadcastPreparer.h"
#import "../Utilities/LCUtils.h"
#import "../../LiveContainer/LCSharedUtils.h"
#import "../../LiveBroadcastExtension/LCBroadcastShared.h"
#import <mach-o/loader.h>

static NSError *LCBError(NSString *message) {
    return [NSError errorWithDomain:@"LiveContainer.Broadcast" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

static uint32_t rnd8(uint32_t v) { return (v + 7) & ~7u; }

/// Lets the guest extension find the guest app's Frameworks from its own folder, as it would natively.
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

@implementation LCBroadcastPreparer

+ (NSUserDefaults *)shared {
    return [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
}

+ (NSString *)broadcastAppexInBundle:(NSString *)bundlePath {
    NSString *plugins = [bundlePath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        if (![name hasSuffix:@".appex"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        if ([info[@"NSExtension"][@"NSExtensionPointIdentifier"] isEqual:@"com.apple.broadcast-services-upload"]) return name;
    }
    return nil;
}

+ (NSDictionary *)guests {
    return [[self shared] dictionaryForKey:kLCBroadcastGuestsKey] ?: @{};
}

+ (void)setGuest:(nullable NSDictionary *)entry forFolder:(NSString *)folder {
    NSMutableDictionary *all = [[self guests] mutableCopy];
    all[folder] = entry;
    [[self shared] setObject:all forKey:kLCBroadcastGuestsKey];
}

+ (void)prepareBundle:(NSString *)bundlePath folder:(NSString *)folder isShared:(BOOL)isShared
           completion:(void (^)(NSError *))completion {
    void (^done)(NSError *) = ^(NSError *e) {
        if (e) NSLog(@"[LCBroadcast] couldn't prepare %@: %@", folder, e.localizedDescription);
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(e); });
    };
    NSString *appex = [self broadcastAppexInBundle:bundlePath];
    if (!appex || !folder.length) { [self setGuest:nil forFolder:folder]; return done(nil); }
    if (!LCUtils.certificateData) {
        return done(LCBError(@"Screen broadcast needs LiveContainer's signing certificate (JIT-less mode)."));
    }
    NSString *appexPath = [bundlePath stringByAppendingFormat:@"/PlugIns/%@", appex];
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[appexPath stringByAppendingPathComponent:@"Info.plist"]];
    NSString *principal = info[@"NSExtension"][@"NSExtensionPrincipalClass"];
    NSString *exec = info[@"CFBundleExecutable"];
    if (!principal || !exec) return done(LCBError(@"The app's broadcast extension is missing its principal class."));

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dylib = [appexPath stringByAppendingPathComponent:kLCBroadcastDylibName];
    [fm removeItemAtPath:dylib error:nil];
    NSError *error = nil;
    if (![fm copyItemAtPath:[appexPath stringByAppendingPathComponent:exec] toPath:dylib error:&error]) return done(error);
    NSString *patchError = LCParseMachO(dylib.fileSystemRepresentation, false, ^(const char *path, struct mach_header_64 *header, int fd, void *filePtr) {
        LCPatchExecSlice(path, header, false);
        addFrameworksRPath(header);
    });
    if (patchError) { [fm removeItemAtPath:dylib error:nil]; return done(LCBError(patchError)); }

    [LCUtils signFilesWithZSignWithURLs:@[[NSURL fileURLWithPath:dylib]] completionHandler:^(BOOL success, NSError *signError) {
        if (!success) {
            [fm removeItemAtPath:dylib error:nil];
            return done(signError ?: LCBError(@"Signing the broadcast code failed."));
        }
        NSDictionary *bundleInfo = [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"Info.plist"]];
        [self setGuest:@{
            kLCBroadcastBundleId: bundleInfo[@"CFBundleIdentifier"] ?: @"",
            kLCBroadcastFolder: folder,
            kLCBroadcastIsShared: @(isShared),
            kLCBroadcastAppex: appex,
            kLCBroadcastPrincipalClass: principal,
        } forFolder:folder];
        done(nil);
    }];
}

+ (void)syncApps:(NSArray<NSDictionary *> *)apps {
    // Builds before automatic broadcast kept a single selected app; its code is reused below.
    [[self shared] removeObjectForKey:@"LCBroadcastGuest"];
    NSMutableArray<NSDictionary *> *todo = [NSMutableArray new];
    NSMutableSet<NSString *> *present = [NSMutableSet new];
    NSDictionary *guests = [self guests];
    for (NSDictionary *app in apps) {
        NSString *path = app[@"bundlePath"], *folder = app[@"folder"];
        if (!path.length || !folder.length) continue;
        NSString *appex = [self broadcastAppexInBundle:path];
        if (!appex) continue;
        [present addObject:folder];
        NSString *dylib = [path stringByAppendingFormat:@"/PlugIns/%@/%@", appex, kLCBroadcastDylibName];
        if (!guests[folder] || ![NSFileManager.defaultManager fileExistsAtPath:dylib]) [todo addObject:app];
    }
    for (NSString *folder in guests) {
        if (![present containsObject:folder]) [self setGuest:nil forFolder:folder];
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

+ (void)forgetFolder:(NSString *)folder {
    [self setGuest:nil forFolder:folder];
}

@end
