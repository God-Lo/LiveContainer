//
//  LCGuestIntentHost.m
//  LiveContainer (fork)
//
//  Host side of Shortcuts forwarding. Lives in LiveContainerShared so it is active in every mode of the
//  main app: LiveContainer's own UI and while LiveContainer is running some other guest app.
// Guest apps' actions are merged into LiveContainer's
//  Metadata.appintents on the phone (LCGuestIntentsMerger + LCShortcutsSelfUpdate), so iOS sends them to
//  LiveContainer. Their Swift types live in the guest binary, which is not loaded here, so we
//  intercept the App Intents perform request, start the owning guest in LiveProcess, and have it
//  perform the action there (LiveProcess/Fork/LCGuestIntentClient.m).
//
//  Private API: -[LNClientConnection performAction:options:executor:completionHandler:] (AppIntents
//  framework, present on iOS 27.0.1). If it is missing, nothing is hooked and guest actions fail the
//  way they would without this file; the "Open App" / "Open URL in App" actions still work.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "../../FoundationPrivate.h"
#import "../../utils.h"
#import "../../LCSharedUtils.h"
#import "../../../LiveProcess/Fork/LCGuestIntentProtocol.h"

typedef void (^LCGIPerformCompletion)(id result, NSError *error);

// Looked up at run time: LiveContainerShared does not link the Swift runtime itself.
typedef const void *(*LCGIGetTypeByMangledName)(const char *name, size_t length, const void *context, const void *const *args);

static NSError *LCGIError(NSString *message) {
    return [NSError errorWithDomain:@"LiveContainer.GuestIntent" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static NSString *liveProcessBundleId;

static NSString *lcHomePath(void) {
    const char *home = getenv("LC_HOME_PATH");
    return home ? @(home) : NSHomeDirectory();
}

#pragma mark - One running guest

@interface LCGuestIntentSession : NSObject <NSXPCListenerDelegate, LCGuestIntentHost>
@property NSString *bundleId;
@property NSXPCListener *listener;
@property NSXPCConnection *connection;
@property NSExtension *extension;
@property BOOL ready;
@property BOOL dead;
/// Bumped whenever work starts, so a pending idle shutdown knows it is stale.
@property NSUInteger generation;
/// Work waiting for the guest to finish launching.
@property NSMutableArray<dispatch_block_t> *pending;
@property NSMutableDictionary<NSString *, LCGIPerformCompletion> *completions;
@end

@implementation LCGuestIntentSession

- (instancetype)initWithBundleId:(NSString *)bundleId {
    self = [super init];
    _bundleId = bundleId;
    _pending = [NSMutableArray array];
    _completions = [NSMutableDictionary dictionary];
    return self;
}

/// LiveContainer addresses apps by their folder under Applications (e.g. "com.foo.app" or
/// "com.foo_1730000000.app"), not by bundle ID. Find the folder holding this bundle ID, preferring a
/// visible copy when the same app is installed more than once.
+ (NSString *)folderForBundleId:(NSString *)bundleId {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = lcHomePath();
    NSArray<NSString *> *roots = @[
        [home stringByAppendingPathComponent:@"Documents/Applications"],
        [[LCSharedUtils appGroupPath] URLByAppendingPathComponent:@"LiveContainer/Applications"].path ?: @"",
    ];
    NSString *hiddenMatch = nil;
    for (NSString *root in roots) {
        for (NSString *folder in [fm contentsOfDirectoryAtPath:root error:nil]) {
            if (![folder hasSuffix:@".app"]) continue;
            NSString *path = [root stringByAppendingPathComponent:folder];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Info.plist"]];
            if (![info[@"CFBundleIdentifier"] isEqual:bundleId]) continue;
            NSDictionary *lcInfo = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"LCAppInfo.plist"]];
            if (![lcInfo[@"isHidden"] boolValue]) return folder;
            hiddenMatch = hiddenMatch ?: folder;
        }
    }
    return hiddenMatch;
}

- (NSError *)start {
    NSString *folder = [LCGuestIntentSession folderForBundleId:self.bundleId];
    bool isShared = false;
    NSBundle *bundle = folder ? [LCSharedUtils findBundleWithBundleId:folder isSharedAppOut:&isShared] : nil;
    NSLog(@"[LCGI] host: start %@ folder=%@ found=%d", self.bundleId, folder, bundle != nil);
    if (!bundle) return LCGIError([NSString stringWithFormat:@"%@ is no longer installed in LiveContainer.", self.bundleId]);
    NSDictionary *appInfo = [NSDictionary dictionaryWithContentsOfFile:[bundle.bundlePath stringByAppendingPathComponent:@"LCAppInfo.plist"]];
    NSString *dataUUID = appInfo[@"LCDataUUID"];

    NSError *error = nil;
    self.extension = liveProcessBundleId ? [NSExtension extensionWithIdentifier:liveProcessBundleId error:&error] : nil;
    if (!self.extension) {
        return LCGIError([NSString stringWithFormat:@"Could not start LiveProcess (%@). Reinstall LiveContainer keeping all app extensions.", error.localizedDescription]);
    }
    self.extension.preferredLanguages = @[];

    self.listener = [NSXPCListener anonymousListener];
    self.listener.delegate = self;
    [self.listener resume];

    // While a guest runs here, HOME points at the guest's container; LC_HOME_PATH is LiveContainer's own.
    NSURL *docURL = [NSURL fileURLWithPath:[lcHomePath() stringByAppendingPathComponent:@"Documents"]];
    NSData *docBookmark = [docURL bookmarkDataWithOptions:(1 << 11) includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    NSMutableDictionary *userInfo = [@{
        @"hostUrlScheme": NSUserDefaults.lcAppUrlScheme ?: @"livecontainer",
        @"selected": folder,
        @"bookmarks": docBookmark ? @[docBookmark] : @[],
        @"lcHomePath": lcHomePath(),
        kLCGuestIntentEndpointKey: self.listener.endpoint,
    } mutableCopy];
    if (dataUUID) userInfo[@"selectedContainer"] = dataUUID;
    NSExtensionItem *item = [NSExtensionItem new];
    item.userInfo = userInfo;

    __weak typeof(self) weakSelf = self;
    void (^onGone)(void) = ^{ NSLog(@"[LCGI] host: LiveProcess interrupted/cancelled"); [weakSelf failAll:@"The guest app quit before finishing the action."]; };
    [self.extension setRequestInterruptionBlock:^(NSUUID *uuid) { onGone(); }];
    [self.extension setRequestCancellationBlock:^(NSUUID *uuid, NSError *err) { onGone(); }];
    NSExtension *ext = self.extension;
    [ext beginExtensionRequestWithInputItems:@[item] completion:^(NSUUID *uuid) {
        NSLog(@"[LCGI] host: LiveProcess request %@ pid=%d", uuid, uuid ? [ext pidForRequestIdentifier:uuid] : -1);
    }];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!weakSelf.ready) [weakSelf failAll:@"The guest app did not finish launching in time."];
    });
    return nil;
}

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    NSLog(@"[LCGI] host: guest connected pid=%d", connection.processIdentifier);
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCGuestIntentHost)];
    connection.exportedObject = self;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCGuestIntentGuest)];
    __weak typeof(self) weakSelf = self;
    connection.invalidationHandler = ^{ [weakSelf failAll:@"Lost connection to the guest app."]; };
    self.connection = connection;
    [connection resume];
    return YES;
}

- (void)guestDidFinishLaunching {
    NSLog(@"[LCGI] host: guest finished launching");
    dispatch_async(dispatch_get_main_queue(), ^{
        self.ready = YES;
        NSArray *work = self.pending.copy;
        [self.pending removeAllObjects];
        for (dispatch_block_t block in work) block();
    });
}

- (void)actionWithToken:(NSString *)token didFinishWithResult:(NSData *)resultData error:(NSString *)errorMessage {
    NSLog(@"[LCGI] host: action %@ finished result=%lu bytes error=%@", token, (unsigned long)resultData.length, errorMessage);
    dispatch_async(dispatch_get_main_queue(), ^{
        LCGIPerformCompletion completion = self.completions[token];
        if (!completion) return;
        [self.completions removeObjectForKey:token];
        id result = nil;
        if (resultData) {
            NSKeyedUnarchiver *u = [[NSKeyedUnarchiver alloc] initForReadingFromData:resultData error:nil];
            u.requiresSecureCoding = NO;
            result = [u decodeObjectForKey:NSKeyedArchiveRootObjectKey];
        }
        completion(result, errorMessage ? LCGIError(errorMessage) : nil);
        [self scheduleIdleShutdown];
    });
}

/// iOS suspends an idle LiveProcess after a few minutes, and messages to it then go unanswered. So
/// never keep one around: stop it shortly after its last action and start a fresh one next time.
- (void)scheduleIdleShutdown {
    if (self.completions.count || self.pending.count) return;
    NSUInteger generation = ++self.generation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        LCGuestIntentSession *session = weakSelf;
        if (!session || session.generation != generation || session.completions.count || session.pending.count) return;
        [session shutdown];
    });
}

- (void)shutdown {
    if (self.dead) return;
    NSLog(@"[LCGI] host: stopping LiveProcess for %@", self.bundleId);
    self.dead = YES;
    [self.connection invalidate];
    [self.listener invalidate];
    [self.extension _kill:9];
}

- (void)perform:(NSData *)actionData identifier:(NSString *)identifier completion:(LCGIPerformCompletion)completion {
    NSString *token = NSUUID.UUID.UUIDString;
    self.completions[token] = completion;
    self.generation++;
    __weak typeof(self) weakSelf = self;
    // Shortcuts gives up on its own after a while; answer before that and start fresh next time.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 45 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        LCGuestIntentSession *session = weakSelf;
        if (!session.completions[token]) return;
        [session actionWithToken:token didFinishWithResult:nil error:@"The app did not finish the action in time."];
        [session shutdown];
    });
    dispatch_block_t send = ^{
        id<LCGuestIntentGuest> guest = [weakSelf.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            [weakSelf actionWithToken:token didFinishWithResult:nil error:error.localizedDescription];
        }];
        NSLog(@"[LCGI] host: sending %@ to guest", identifier);
        [guest performAction:actionData identifier:identifier token:token];
    };
    if (self.ready && self.connection) send(); else [self.pending addObject:send];
}

- (void)failAll:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.pending removeAllObjects];
        [self shutdown];
        NSDictionary *completions = self.completions.copy;
        [self.completions removeAllObjects];
        NSLog(@"[LCGI] host: failing %lu action(s): %@", (unsigned long)completions.count, message);
        for (LCGIPerformCompletion completion in completions.allValues) completion(nil, LCGIError(message));
    });
}

@end

#pragma mark - Routing

@interface LCGuestIntentHost : NSObject
@end

@implementation LCGuestIntentHost

static NSDictionary<NSString *, NSDictionary *> *guestIntentMap;
static NSMutableDictionary<NSString *, LCGuestIntentSession *> *sessions;

static BOOL typeResolvesHere(NSString *mangled) {
    static LCGIGetTypeByMangledName getType;
    if (!getType) getType = (LCGIGetTypeByMangledName)dlsym(RTLD_DEFAULT, "swift_getTypeByMangledNameInContext");
    if (!getType || mangled.length == 0) return NO;
    const char *name = mangled.UTF8String;
    return getType(name, strlen(name), NULL, NULL) != NULL;
}

/// Returns YES if the action belongs to a guest that is not loaded in this process and was handed off.
static BOOL forwardIfGuestAction(id action, LCGIPerformCompletion completion) {
    NSString *identifier = [action valueForKey:@"identifier"];
    NSDictionary *entry = identifier ? guestIntentMap[identifier] : nil;
    if (!entry) return NO;
    NSString *mangled = [action valueForKey:@"mangledTypeName"] ?: entry[@"mangledTypeName"];
    BOOL local = typeResolvesHere(mangled);
    NSLog(@"[LCGI] host: perform %@ (%@) for %@ local=%d", identifier, mangled, entry[@"bundleId"], local);
    // The guest is running in this process (LiveContainer launched it), so App Intents can run it directly.
    if (local) return NO;

    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:action requiringSecureCoding:NO error:nil];
    if (!archived) {
        completion(nil, LCGIError(@"LiveContainer could not forward this action."));
        return YES;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *bundleId = entry[@"bundleId"];
        LCGuestIntentSession *session = sessions[bundleId];
        if (!session || session.dead) {
            session = [[LCGuestIntentSession alloc] initWithBundleId:bundleId];
            NSError *error = [session start];
            if (error) {
                completion(nil, error);
                return;
            }
            sessions[bundleId] = session;
        }
        [session perform:archived identifier:entry[@"identifier"] completion:completion];
    });
    return YES;
}

+ (void)load {
    // LiveContainerShared is also loaded by LiveProcess and the other extensions; only the app itself
    // receives Shortcuts actions. At +load time mainBundle is still LiveContainer, before a guest
    // replaces it.
    NSBundle *lcBundle = NSBundle.mainBundle;
    if ([lcBundle.bundlePath hasSuffix:@".appex"]) return;
    liveProcessBundleId = [NSBundle bundleWithPath:[lcBundle.builtInPlugInsPath stringByAppendingPathComponent:@"LiveProcess.appex"]].bundleIdentifier;
    NSString *mapPath = [lcBundle pathForResource:@"LCGuestIntentsMap" ofType:@"plist"];
    guestIntentMap = mapPath ? [NSDictionary dictionaryWithContentsOfFile:mapPath] : nil;
    if (guestIntentMap.count == 0) return;
    sessions = [NSMutableDictionary dictionary];

    dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_LAZY);
    Class cls = NSClassFromString(@"LNClientConnection");
    SEL sel = NSSelectorFromString(@"performAction:options:executor:completionHandler:");
    Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
    if (!method) {
        NSLog(@"[LC] LNClientConnection perform hook unavailable; guest Shortcuts actions disabled");
        return;
    }
    typedef void (*PerformIMP)(id, SEL, id, id, id, LCGIPerformCompletion);
    __block PerformIMP original = NULL;
    IMP replacement = imp_implementationWithBlock(^(id connection, id action, id options, id executor, LCGIPerformCompletion completion) {
        if (completion && forwardIfGuestAction(action, completion)) return;
        original(connection, sel, action, options, executor, completion);
    });
    original = (PerformIMP)method_setImplementation(method, replacement);
    NSLog(@"[LCGI] host: hook installed for %lu action(s)", (unsigned long)guestIntentMap.count);
}

@end
