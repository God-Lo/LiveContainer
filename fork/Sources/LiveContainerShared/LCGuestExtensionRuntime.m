//
//  LCGuestExtensionRuntime.m
//  LiveContainer (fork)
//
//  Runs when LiveContainerShared loads:
//  - In an app's extension copied into LiveContainer (its Info.plist has LCGuestExtension): sets up the
//    app's environment before the extension's own code runs, the way LiveContainer does for the app:
//    its data folder as home, and its app groups and UserDefaults suites redirected to the same places
//    the app uses inside LiveContainer.
//  - In LiveContainer, LiveProcess and the copied extensions: calls that name an app's extension by its
//    own bundle ID (content blocker and call directory reloads, the broadcast picker's preferred
//    extension) are pointed at its copy in LiveContainer.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "LCGuestExtension.h"
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

/// An app's own extension bundle ID -> its copy's bundle ID in this LiveContainer.
static NSDictionary<NSString *, NSString *> *extensionIdMap;

static void setUpGuestExtension(NSDictionary *ext) {
    NSString *groupId = [LCSharedUtils appGroupID];
    lcUserDefaults = NSUserDefaults.standardUserDefaults;
    lcSharedDefaults = [[NSUserDefaults alloc] initWithSuiteName:groupId];
    lcAppGroupPath = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:groupId].path;
    if (!lcAppGroupPath) { NSLog(@"[LCGuestExtension] no app group"); return; }

    // Where the app lives: the app group for shared apps, LiveContainer's Documents otherwise (reached
    // through the bookmark LiveContainer leaves; some extensions, like keyboards, may not reach it).
    isSharedBundle = [ext[kLCGEIsShared] boolValue];
    NSString *root = nil;
    if (isSharedBundle) {
        root = [lcAppGroupPath stringByAppendingPathComponent:@"LiveContainer"];
    } else {
        NSData *bookmark = [lcSharedDefaults dataForKey:@"LCLaunchExtensionPrivateDocBookmark"];
        BOOL stale = NO;
        NSURL *docs = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&stale error:nil] : nil;
        if (docs && [docs startAccessingSecurityScopedResource]) {
            root = docs.path;
            setenv("LC_HOME_PATH", docs.URLByDeletingLastPathComponent.path.fileSystemRepresentation, 1);
        }
    }
    NSString *bundlePath = root ? [root stringByAppendingFormat:@"/Applications/%@", ext[kLCGEFolder]] : nil;
    guestAppInfo = bundlePath ? [NSDictionary dictionaryWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]] : nil;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home;
    if (guestAppInfo[@"LCDataUUID"]) {
        home = [root stringByAppendingFormat:@"/Data/Application/%@", guestAppInfo[@"LCDataUUID"]];
    } else {
        // The app's data can't be reached from here: use a home of its own in the app group. App groups
        // still work; settings the app keeps outside them aren't shared.
        home = [lcAppGroupPath stringByAppendingFormat:@"/LiveContainer/Data/ExtensionHome/%@", ext[kLCGEFolder]];
        guestAppInfo = guestAppInfo ?: @{};
    }
    for (NSString *sub in @[@"Library/Preferences", @"Library/Caches", @"Documents", @"tmp"]) {
        [fm createDirectoryAtPath:[home stringByAppendingPathComponent:sub] withIntermediateDirectories:YES attributes:nil error:nil];
    }
    setenv("CFFIXED_USER_HOME", home.fileSystemRepresentation, 1);
    setenv("HOME", home.fileSystemRepresentation, 1);
    setenv("TMPDIR", [home stringByAppendingPathComponent:@"tmp"].fileSystemRepresentation, 1);
    guestContainerInfo = [NSDictionary dictionaryWithContentsOfFile:[home stringByAppendingPathComponent:@"LCContainerInfo.plist"]];
    // The extension's own settings, as natively (not the app's).
    lcGuestAppId = ext[kLCGEAppexBundleId] ?: ext[kLCGEAppBundleId];
    NUDGuestHooksInit();
    NSFMGuestHooksInit();
    NSLog(@"[LCGuestExtension] %@ for %@ (home %@)", ext[kLCGEAppexBundleId], ext[kLCGEAppName], root ? @"app's" : @"fallback");
}

/// LiveContainer.app, from any of its processes.
static NSString *liveContainerAppPath(void) {
    NSString *path = NSBundle.mainBundle.bundlePath;
    return [path hasSuffix:@".appex"] ? path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent : path;
}

NSArray<NSDictionary *> *LCHostedGuestExtensions(NSString *point) {
    NSString *folder = [liveContainerAppPath() stringByAppendingPathComponent:kLCHostedExtensionsFolder];
    NSMutableArray *found = [NSMutableArray new];
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:folder error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *path = [folder stringByAppendingPathComponent:name];
        NSMutableDictionary *info = [[NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]] mutableCopy];
        if (!info[kLCGuestExtensionInfoKey] || ![info[@"NSExtension"][@"NSExtensionPointIdentifier"] isEqual:point]) continue;
        info[@"path"] = path;
        [found addObject:info];
    }
    return found;
}

BOOL LCLoadHostedGuestExtension(NSDictionary *entry, NSString **error) {
    static NSString *loaded;
    NSString *path = entry[@"path"];
    if (loaded) {
        if ([loaded isEqualToString:path]) return YES;
        if (error) *error = @"Another app's extension already ran here. Share again to use this one.";
        return NO;
    }
    if (!LCLoadHostedGuestExtensionCode(entry, error)) return NO;
    loaded = path;
    return YES;
}

BOOL LCLoadHostedGuestExtensionCode(NSDictionary *entry, NSString **error) {
    static NSMutableSet<NSString *> *loadedIds;
    static BOOL environmentSet;
    if (!loadedIds) loadedIds = [NSMutableSet new];
    // The same app's extension (another copy of the app) is already loaded: its classes are there.
    NSString *appexId = entry[kLCGuestExtensionInfoKey][kLCGEAppexBundleId] ?: entry[@"path"];
    if ([loadedIds containsObject:appexId]) return YES;
    // The first app gets this process's environment (home folder, settings, Bundle.main).
    if (!environmentSet) setUpGuestExtension(entry[kLCGuestExtensionInfoKey]);
    NSString *dylib = [entry[@"path"] stringByAppendingPathComponent:kLCHostedDylibName];
    if (!dlopen(dylib.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        if (error) *error = [NSString stringWithFormat:@"Couldn't load the app's extension: %s", dlerror()];
        return NO;
    }
    if (!environmentSet) {
        // The extension finds its storyboards and resources through Bundle.main.
        NSBundle *bundle = [NSBundle bundleWithPath:entry[@"path"]];
        if (bundle) overwriteMainNSBundle(bundle);
        environmentSet = YES;
    }
    [loadedIds addObject:appexId];
    return YES;
}

static NSString *mapId(NSString *identifier) {
    NSString *mapped = identifier ? extensionIdMap[identifier] : nil;
    return mapped ?: identifier;
}

static void replaceMethod(Class cls, SEL sel, BOOL classMethod, id (^makeBlock)(IMP orig)) {
    if (!cls) return;
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, imp_implementationWithBlock(makeBlock(method_getImplementation(m))));
}

/// Kinds of apps' extensions copied into this LiveContainer.
static NSSet<NSString *> *copiedKinds;
/// YES in an app's extension copied into LiveContainer.
static BOOL inCopiedExtension;

/// The class to hook, or nil when hooking it would do nothing. Its framework is only loaded when a hook
/// is needed and the app could still load it later; frameworks loaded for nothing slow every app's
/// start and use memory, which extensions like keyboards have little of.
static Class hookTarget(NSString *className, const char *framework, BOOL needed) {
    if (!needed) return nil;
    Class cls = NSClassFromString(className);
    // A copied extension's frameworks are all loaded by now: if it isn't there, the extension doesn't use it.
    if (cls || inCopiedExtension) return cls;
    dlopen(framework, RTLD_LAZY);
    return NSClassFromString(className);
}

static void installIdHooks(void) {
    // Without a copy of that kind there is nothing to point at, so these are left alone.
    Class blocker = hookTarget(@"SFContentBlockerManager", "/System/Library/Frameworks/SafariServices.framework/SafariServices",
                               [copiedKinds containsObject:kLCPointContentBlocker]);
    for (NSString *name in @[@"reloadContentBlockerWithIdentifier:completionHandler:", @"getStateOfContentBlockerWithIdentifier:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        replaceMethod(blocker, sel, YES, ^id(IMP orig) {
            return ^(id self, NSString *identifier, id completion) {
                ((void (*)(id, SEL, NSString *, id))orig)(self, sel, mapId(identifier), completion);
            };
        });
    }
    Class calls = hookTarget(@"CXCallDirectoryManager", "/System/Library/Frameworks/CallKit.framework/CallKit",
                             [copiedKinds containsObject:kLCPointCallDirectory]);
    for (NSString *name in @[@"reloadExtensionWithIdentifier:completionHandler:", @"getEnabledStatusForExtensionWithIdentifier:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        replaceMethod(calls, sel, NO, ^id(IMP orig) {
            return ^(id self, NSString *identifier, id completion) {
                ((void (*)(id, SEL, NSString *, id))orig)(self, sel, mapId(identifier), completion);
            };
        });
    }
    // Apps' own Files locations aren't used inside LiveContainer (it shows a folder per app instead):
    // their add/remove requests succeed without doing anything. LiveContainer's own locations (lc.files.*) pass.
    Class fpm = hookTarget(@"NSFileProviderManager", "/System/Library/Frameworks/FileProvider.framework/FileProvider", YES);
    for (NSString *name in @[@"addDomain:completionHandler:", @"removeDomain:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        replaceMethod(fpm, sel, YES, ^id(IMP orig) {
            return ^(id self, id domain, void (^completion)(NSError *)) {
                if ([[domain valueForKey:@"identifier"] hasPrefix:@"lc.files."]) {
                    ((void (*)(id, SEL, id, id))orig)(self, sel, domain, completion);
                } else if (completion) {
                    completion(nil);
                }
            };
        });
    }
    SEL setPreferred = @selector(setPreferredExtension:);
    Class picker = hookTarget(@"RPSystemBroadcastPickerView", "/System/Library/Frameworks/ReplayKit.framework/ReplayKit",
                              [copiedKinds containsObject:kLCPointBroadcast]);
    replaceMethod(picker, setPreferred, NO, ^id(IMP orig) {
        return ^(id self, NSString *identifier) {
            ((void (*)(id, SEL, NSString *))orig)(self, setPreferred, mapId(identifier));
        };
    });
}

#pragma mark - Accessory access (AccessorySetupKit)

/// This process's own bundle ID, read before an app replaces Bundle.main.
static NSString *processBundleId;

/// An app's accessory requests (AccessorySetupKit, through the private DeviceAccess framework) name the
/// app by Bundle.main, which inside LiveContainer is the app's own ID. iOS only accepts the ID of the
/// installed app, LiveContainer, whose Info.plist holds the app's accessory settings (the Accessory
/// Setup switch). So the app's ID is replaced with this process's own in those requests.
static NSString *accessoryBundleId(NSString *value) {
    NSString *guestId = NSBundle.mainBundle.bundleIdentifier;
    if (!processBundleId || (value && ![value isEqualToString:guestId])) return value;
    return processBundleId;
}

static void hookDeviceAccess(void) {
    unsigned count = 0;
    const char *image = "/System/Library/PrivateFrameworks/DeviceAccess.framework/DeviceAccess";
    const char **names = objc_copyClassNamesForImage(image, &count);
    for (unsigned i = 0; i < count; i++) {
        Class cls = objc_getClass(names[i]);
        for (NSString *name in @[@"setBundleID:", @"setBundleIdentifier:", @"setAppBundleID:"]) {
            SEL sel = NSSelectorFromString(name);
            Method m = class_getInstanceMethod(cls, sel);
            // Only the class's own setter, so a subclass isn't hooked twice.
            if (!m || method_getImplementation(m) != class_getMethodImplementation(cls, sel)) continue;
            unsigned own = 0;
            Method *list = class_copyMethodList(cls, &own);
            BOOL declared = NO;
            for (unsigned j = 0; j < own; j++) if (method_getName(list[j]) == sel) declared = YES;
            free(list);
            if (!declared) continue;
            replaceMethod(cls, sel, NO, ^id(IMP orig) {
                return ^(id self, NSString *value) {
                    ((void (*)(id, SEL, NSString *))orig)(self, sel, accessoryBundleId(value));
                };
            });
        }
    }
    free(names);
    // A session that's never given an ID is filled in when it starts.
    SEL activate = @selector(activate);
    replaceMethod(objc_getClass("DASession"), activate, NO, ^id(IMP orig) {
        return ^(id self) {
            if ([self respondsToSelector:@selector(setBundleID:)] && ![self valueForKey:@"bundleID"]) {
                [self setValue:accessoryBundleId(nil) forKey:@"bundleID"];
            }
            ((void (*)(id, SEL))orig)(self, activate);
        };
    });
    NSLog(@"[LCGuestExtension] accessory requests use %@", processBundleId);
}

__attribute__((constructor)) static void LCGuestExtensionRuntimeInit(void) {
    NSBundle *main = NSBundle.mainBundle;
    NSDictionary *ext = main.infoDictionary[kLCGuestExtensionInfoKey];
    NSString *appPath = main.bundlePath;
    if ([appPath hasSuffix:@".appex"]) {
        // Other LiveContainer extensions don't run apps.
        if (!ext && ![appPath.lastPathComponent isEqualToString:@"LiveProcess.appex"]) return;
        appPath = appPath.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    }
    inCopiedExtension = ext != nil;
    if (ext) setUpGuestExtension(ext);

    NSMutableDictionary *map = [NSMutableDictionary new];
    NSMutableSet *kinds = [NSMutableSet new];
    NSString *plugins = [appPath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        NSString *original = info[kLCGuestExtensionInfoKey][kLCGEAppexBundleId];
        if (!original || !info[@"CFBundleIdentifier"]) continue;
        map[original] = info[@"CFBundleIdentifier"];
        NSString *kind = info[@"NSExtension"][@"NSExtensionPointIdentifier"];
        if (kind) [kinds addObject:kind];
    }
    extensionIdMap = map;
    copiedKinds = kinds;
    installIdHooks();
    // Where apps run (not in copied extensions), when an app's Accessory Setup is on: LiveContainer's
    // Info.plist then has the accessory settings. Before an app replaces Bundle.main.
    NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]];
    if (!ext && [lcInfo[@"NSAccessorySetupKitSupports"] count]) {
        processBundleId = main.bundleIdentifier;
        if (dlopen("/System/Library/PrivateFrameworks/DeviceAccess.framework/DeviceAccess", RTLD_LAZY)) hookDeviceAccess();
    }
}
