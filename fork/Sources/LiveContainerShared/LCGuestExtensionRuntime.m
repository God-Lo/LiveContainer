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

static NSString *mapId(NSString *identifier) {
    NSString *mapped = identifier ? extensionIdMap[identifier] : nil;
    return mapped ?: identifier;
}

static void replaceMethod(Class cls, SEL sel, BOOL classMethod, id (^makeBlock)(IMP orig)) {
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, imp_implementationWithBlock(makeBlock(method_getImplementation(m))));
}

static void installIdHooks(void) {
    dlopen("/System/Library/Frameworks/SafariServices.framework/SafariServices", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/CallKit.framework/CallKit", RTLD_LAZY);
    dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", RTLD_LAZY);
    Class blocker = NSClassFromString(@"SFContentBlockerManager");
    for (NSString *name in @[@"reloadContentBlockerWithIdentifier:completionHandler:", @"getStateOfContentBlockerWithIdentifier:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        replaceMethod(blocker, sel, YES, ^id(IMP orig) {
            return ^(id self, NSString *identifier, id completion) {
                ((void (*)(id, SEL, NSString *, id))orig)(self, sel, mapId(identifier), completion);
            };
        });
    }
    Class calls = NSClassFromString(@"CXCallDirectoryManager");
    for (NSString *name in @[@"reloadExtensionWithIdentifier:completionHandler:", @"getEnabledStatusForExtensionWithIdentifier:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        replaceMethod(calls, sel, NO, ^id(IMP orig) {
            return ^(id self, NSString *identifier, id completion) {
                ((void (*)(id, SEL, NSString *, id))orig)(self, sel, mapId(identifier), completion);
            };
        });
    }
    SEL setPreferred = @selector(setPreferredExtension:);
    replaceMethod(NSClassFromString(@"RPSystemBroadcastPickerView"), setPreferred, NO, ^id(IMP orig) {
        return ^(id self, NSString *identifier) {
            ((void (*)(id, SEL, NSString *))orig)(self, setPreferred, mapId(identifier));
        };
    });
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
    if (ext) setUpGuestExtension(ext);

    NSMutableDictionary *map = [NSMutableDictionary new];
    NSString *plugins = [appPath stringByAppendingPathComponent:@"PlugIns"];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:plugins error:nil]) {
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[plugins stringByAppendingFormat:@"/%@/Info.plist", name]];
        NSString *original = info[kLCGuestExtensionInfoKey][kLCGEAppexBundleId];
        if (original && info[@"CFBundleIdentifier"]) map[original] = info[@"CFBundleIdentifier"];
    }
    extensionIdMap = map;
    if (map.count) installIdHooks();
}
