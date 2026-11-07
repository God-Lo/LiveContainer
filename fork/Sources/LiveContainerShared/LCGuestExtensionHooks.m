//
//  LCGuestExtensionHooks.m
//  LiveContainer (fork)
//
//  Runs in LiveContainer and LiveProcess, where apps run. Points apps' calls about their own
//  extensions at LiveContainer's extensions:
//  - Safari content blocker: apps reload or query their blocker by its bundle ID; inside LiveContainer
//    that blocker is LiveContainer's AppsContentBlocker.
//  - File Provider: domains an app adds belong to LiveContainer's File Provider; remember which app
//    added each, so the File Provider runs that app's code for it.
//  - Screen broadcast picker: an app's preferred extension is LiveContainer's broadcast extension.
//  - Call blocking & identification: apps reload or query their extension by its bundle ID.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "LCGuestExtension.h"
#import "../../../LiveContainer/LCSharedUtils.h"

extern NSString *lcGuestAppId;

static NSString *lcBundleId;

/// An app's own extension ID -> LiveContainer's extension of that kind.
static NSString *mapId(NSString *identifier, NSString *ourExtension) {
    if (!identifier.length || [identifier hasPrefix:lcBundleId]) return identifier;
    return [NSString stringWithFormat:@"%@.%@", lcBundleId, ourExtension];
}
static NSString *mapBlockerId(NSString *identifier) { return mapId(identifier, @"AppsContentBlocker"); }

static void hookClassMethod(Class cls, SEL sel, id block) {
    Method m = class_getClassMethod(cls, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    objc_setAssociatedObject(cls, sel, [NSValue valueWithPointer:orig], OBJC_ASSOCIATION_RETAIN);
    method_setImplementation(m, imp_implementationWithBlock(block));
}

static IMP origOf(Class cls, SEL sel) {
    return [objc_getAssociatedObject(cls, sel) pointerValue];
}

static void hookContentBlockerManager(void) {
    dlopen("/System/Library/Frameworks/SafariServices.framework/SafariServices", RTLD_LAZY);
    Class cls = NSClassFromString(@"SFContentBlockerManager");
    if (!cls) return;
    SEL reload = NSSelectorFromString(@"reloadContentBlockerWithIdentifier:completionHandler:");
    hookClassMethod(cls, reload, ^(id self, NSString *identifier, id completion) {
        ((void (*)(id, SEL, NSString *, id))origOf(cls, reload))(self, reload, mapBlockerId(identifier), completion);
    });
    SEL state = NSSelectorFromString(@"getStateOfContentBlockerWithIdentifier:completionHandler:");
    hookClassMethod(cls, state, ^(id self, NSString *identifier, id completion) {
        ((void (*)(id, SEL, NSString *, id))origOf(cls, state))(self, state, mapBlockerId(identifier), completion);
    });
}

static void hookFileProviderManager(void) {
    dlopen("/System/Library/Frameworks/FileProvider.framework/FileProvider", RTLD_LAZY);
    Class cls = NSClassFromString(@"NSFileProviderManager");
    if (!cls) return;
    SEL add = NSSelectorFromString(@"addDomain:completionHandler:");
    hookClassMethod(cls, add, ^(id self, id domain, id completion) {
        NSString *domainId = [domain valueForKey:@"identifier"];
        if (domainId && lcGuestAppId) {
            NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
            NSMutableDictionary *map = [[shared dictionaryForKey:kLCFileProviderDomainsKey] mutableCopy] ?: [NSMutableDictionary new];
            map[domainId] = lcGuestAppId;
            [shared setObject:map forKey:kLCFileProviderDomainsKey];
        }
        ((void (*)(id, SEL, id, id))origOf(cls, add))(self, add, domain, completion);
    });
}

static void hookBroadcastPicker(void) {
    dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", RTLD_LAZY);
    Class cls = NSClassFromString(@"RPSystemBroadcastPickerView");
    SEL set = @selector(setPreferredExtension:);
    Method m = cls ? class_getInstanceMethod(cls, set) : NULL;
    if (!m) return;
    void (*orig)(id, SEL, NSString *) = (void *)method_getImplementation(m);
    method_setImplementation(m, imp_implementationWithBlock(^(id self, NSString *identifier) {
        orig(self, set, mapId(identifier, @"LiveBroadcastExtension"));
    }));
}

static void hookCallDirectoryManager(void) {
    dlopen("/System/Library/Frameworks/CallKit.framework/CallKit", RTLD_LAZY);
    Class cls = NSClassFromString(@"CXCallDirectoryManager");
    for (NSString *name in @[@"reloadExtensionWithIdentifier:completionHandler:",
                             @"getEnabledStatusForExtensionWithIdentifier:completionHandler:"]) {
        SEL sel = NSSelectorFromString(name);
        Method m = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!m) continue;
        void (*orig)(id, SEL, NSString *, id) = (void *)method_getImplementation(m);
        method_setImplementation(m, imp_implementationWithBlock(^(id self, NSString *identifier, id completion) {
            orig(self, sel, mapId(identifier, @"AppsCallDirectory"), completion);
        }));
    }
}

__attribute__((constructor)) static void LCGuestExtensionHooksInit(void) {
    NSString *path = NSBundle.mainBundle.bundlePath;
    NSString *appPath = path;
    if ([path hasSuffix:@".appex"]) {
        // Only LiveProcess runs apps; other extensions are LiveContainer's own.
        if (![path.lastPathComponent isEqualToString:@"LiveProcess.appex"]) return;
        appPath = path.stringByDeletingLastPathComponent.stringByDeletingLastPathComponent;
    }
    lcBundleId = [NSDictionary dictionaryWithContentsOfFile:[appPath stringByAppendingPathComponent:@"Info.plist"]][@"CFBundleIdentifier"];
    if (!lcBundleId) return;
    hookContentBlockerManager();
    hookFileProviderManager();
    hookBroadcastPicker();
    hookCallDirectoryManager();
}
