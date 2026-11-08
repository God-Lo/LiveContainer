//
//  LCBackgroundEvents.m
//  LiveContainer (fork)
//
//  App side of Background Events (see LCBackgroundEvents.h): records what an app registers, and in
//  LiveProcess calls the app's own delegates and task handlers with events LiveContainer received.
//
//  System frameworks are reached at run time, so LiveContainerShared doesn't link them into every
//  process that loads it.
//

#import "LCBackgroundEvents.h"
#import "../LiveProcess/LCGuestIntentProtocol.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

extern bool isLiveProcess;  // LCBootstrap.m

// Selectors of system classes, used through `id`.
@protocol LCBESystem
- (void)registerForConnectionEventsWithOptions:(NSDictionary *)options;
- (NSArray *)retrievePeripheralsWithIdentifiers:(NSArray<NSUUID *> *)identifiers;
- (NSInteger)state;
- (id)delegate;
- (NSString *)UUIDString;
- (NSString *)identifier;
- (NSDate *)earliestBeginDate;
- (void)setExpirationHandler:(void (^)(void))handler;
- (void (^)(void))expirationHandler;
@end

static NSString *symbolString(const char *name) {
    NSString *__strong *value = (NSString *__strong *)dlsym(RTLD_DEFAULT, name);
    return value ? *value : nil;
}

static void replaceMethod(Class cls, SEL sel, BOOL classMethod, id (^makeBlock)(IMP orig)) {
    Method m = classMethod ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, imp_implementationWithBlock(makeBlock(method_getImplementation(m))));
}

#pragma mark - Registry

NSString *LCBackgroundEventsFolder(void) {
    NSString *group = [NSFileManager.defaultManager containerURLForSecurityApplicationGroupIdentifier:[LCSharedUtils appGroupID]].path;
    if (!group) return nil;
    NSString *folder = [group stringByAppendingPathComponent:@"LiveContainer/BackgroundEvents"];
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    return folder;
}

static NSArray<NSString *> *enabledApps(void) {
    NSString *folder = LCBackgroundEventsFolder();
    return folder ? [NSArray arrayWithContentsOfFile:[folder stringByAppendingPathComponent:@"apps.plist"]] : nil;
}

/// The app running in this process, when it has Background Events on.
static NSString *currentApp(void) {
    NSString *folder = NSBundle.mainBundle.bundlePath.lastPathComponent;
    return [enabledApps() containsObject:folder] ? folder : nil;
}

static void recordUpdate(void (^change)(NSMutableDictionary *registry)) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("lc.background-events.registry", DISPATCH_QUEUE_SERIAL); });
    NSString *app = currentApp();
    if (!app) return;
    dispatch_async(queue, ^{
        NSString *path = [LCBackgroundEventsFolder() stringByAppendingFormat:@"/%@.plist", app];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSMutableDictionary *registry = data ? [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListMutableContainers format:nil error:nil] : nil;
        if (![registry isKindOfClass:NSMutableDictionary.class]) registry = [NSMutableDictionary new];
        change(registry);
        [[NSPropertyListSerialization dataWithPropertyList:registry format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil] writeToFile:path atomically:YES];
    });
}

static NSMutableDictionary *section(NSMutableDictionary *registry, NSString *key) {
    if (![registry[key] isKindOfClass:NSMutableDictionary.class]) registry[key] = [NSMutableDictionary new];
    return registry[key];
}

static void addUnique(NSMutableDictionary *dict, NSString *key, NSArray *values) {
    NSMutableArray *list = [dict[key] isKindOfClass:NSArray.class] ? [dict[key] mutableCopy] : [NSMutableArray new];
    for (id value in values) if (![list containsObject:value]) [list addObject:value];
    dict[key] = list;
}

#pragma mark - What the app registers

static NSHashTable *centralManagers, *locationManagers;
static NSMutableDictionary<NSString *, NSArray *> *taskHandlers;  // identifier -> [handler, queue?]
static const void *kQueueKey = &kQueueKey;
static const void *kCloserKey = &kCloserKey;

static void installRecorders(void) {
    centralManagers = [NSHashTable weakObjectsHashTable];
    locationManagers = [NSHashTable weakObjectsHashTable];
    taskHandlers = [NSMutableDictionary new];

    Class central = NSClassFromString(@"CBCentralManager");
    NSString *restoreKey = symbolString("CBCentralManagerOptionRestoreIdentifierKey");
    SEL initSel = @selector(initWithDelegate:queue:options:);
    replaceMethod(central, initSel, NO, ^id(IMP orig) {
        // Returns the object as `void *` so ownership passes through an init unchanged.
        return ^void *(__unsafe_unretained id self, id delegate, dispatch_queue_t queue, NSDictionary *options) {
            NSString *restore = restoreKey ? options[restoreKey] : nil;
            BOOL tracked = currentApp() != nil;
            if (tracked && restore) recordUpdate(^(NSMutableDictionary *r) { addUnique(section(r, @"bluetooth"), @"restoreIds", @[restore]); });
            if (isLiveProcess && restore) {
                // Restoration belongs to LiveContainer's process; LiveContainer passes it on.
                NSMutableDictionary *trimmed = options.mutableCopy;
                [trimmed removeObjectForKey:restoreKey];
                options = trimmed;
            }
            void *result = ((void *(*)(id, SEL, id, dispatch_queue_t, NSDictionary *))orig)(self, initSel, delegate, queue, options);
            id manager = (__bridge id)result;
            if (tracked && manager) {
                if (queue) objc_setAssociatedObject(manager, kQueueKey, queue, OBJC_ASSOCIATION_RETAIN);
                [centralManagers addObject:manager];
            }
            return result;
        };
    });
    SEL connSel = @selector(registerForConnectionEventsWithOptions:);
    NSString *servicesKey = symbolString("CBConnectionEventMatchingOptionServiceUUIDs");
    NSString *peripheralsKey = symbolString("CBConnectionEventMatchingOptionPeripheralUUIDs");
    replaceMethod(central, connSel, NO, ^id(IMP orig) {
        return ^(id self, NSDictionary *options) {
            if (currentApp()) {
                NSMutableArray *services = [NSMutableArray new], *peripherals = [NSMutableArray new];
                for (id uuid in (servicesKey ? options[servicesKey] : nil)) [services addObject:[uuid UUIDString]];
                for (id uuid in (peripheralsKey ? options[peripheralsKey] : nil)) [peripherals addObject:[uuid UUIDString]];
                recordUpdate(^(NSMutableDictionary *r) {
                    NSMutableDictionary *bt = section(r, @"bluetooth");
                    bt[@"connectionEvents"] = @YES;
                    addUnique(bt, @"services", services);
                    addUnique(bt, @"peripherals", peripherals);
                });
            }
            ((void (*)(id, SEL, NSDictionary *))orig)(self, connSel, options);
        };
    });

    Class location = NSClassFromString(@"CLLocationManager");
    for (NSString *name in @[@"startMonitoringSignificantLocationChanges", @"stopMonitoringSignificantLocationChanges"]) {
        SEL sel = NSSelectorFromString(name);
        BOOL on = [name hasPrefix:@"start"];
        replaceMethod(location, sel, NO, ^id(IMP orig) {
            return ^(id self) {
                if (currentApp()) {
                    [locationManagers addObject:self];
                    recordUpdate(^(NSMutableDictionary *r) { section(r, @"location")[@"significant"] = @(on); });
                }
                ((void (*)(id, SEL))orig)(self, sel);
            };
        });
    }
    for (NSString *name in @[@"startMonitoringForRegion:", @"stopMonitoringForRegion:"]) {
        SEL sel = NSSelectorFromString(name);
        BOOL on = [name hasPrefix:@"start"];
        replaceMethod(location, sel, NO, ^id(IMP orig) {
            return ^(id self, id region) {
                if (currentApp() && [region identifier]) {
                    [locationManagers addObject:self];
                    NSString *identifier = [region identifier];
                    NSData *archived = on ? [NSKeyedArchiver archivedDataWithRootObject:region requiringSecureCoding:YES error:nil] : nil;
                    recordUpdate(^(NSMutableDictionary *r) {
                        NSMutableDictionary *loc = section(r, @"location");
                        NSMutableDictionary *regions = [loc[@"regions"] isKindOfClass:NSDictionary.class] ? [loc[@"regions"] mutableCopy] : [NSMutableDictionary new];
                        regions[identifier] = archived;
                        loc[@"regions"] = regions;
                    });
                }
                ((void (*)(id, SEL, id))orig)(self, sel, region);
            };
        });
    }

    Class scheduler = NSClassFromString(@"BGTaskScheduler");
    SEL registerSel = @selector(registerForTaskWithIdentifier:usingQueue:launchHandler:);
    replaceMethod(scheduler, registerSel, NO, ^id(IMP orig) {
        return ^BOOL(id self, NSString *identifier, dispatch_queue_t queue, id handler) {
            if (currentApp() && identifier && handler) {
                taskHandlers[identifier] = queue ? @[handler, queue] : @[handler];
                recordUpdate(^(NSMutableDictionary *r) { addUnique(section(r, @"tasks"), @"identifiers", @[identifier]); });
                // In LiveProcess the scheduler isn't available: LiveContainer runs the task and calls this handler.
                if (isLiveProcess) return YES;
            }
            return ((BOOL (*)(id, SEL, NSString *, dispatch_queue_t, id))orig)(self, registerSel, identifier, queue, handler);
        };
    });
    SEL submitSel = @selector(submitTaskRequest:error:);
    replaceMethod(scheduler, submitSel, NO, ^id(IMP orig) {
        return ^BOOL(id self, id request, NSError **error) {
            if (isLiveProcess && currentApp()) {
                NSMutableDictionary *pending = [@{@"identifier": [request identifier] ?: @"",
                                                  @"processing": @([request isKindOfClass:NSClassFromString(@"BGProcessingTaskRequest")])} mutableCopy];
                if ([request earliestBeginDate]) pending[@"date"] = [request earliestBeginDate];
                recordUpdate(^(NSMutableDictionary *r) {
                    NSMutableDictionary *tasks = section(r, @"tasks");
                    NSMutableArray *list = [tasks[@"pending"] isKindOfClass:NSArray.class] ? [tasks[@"pending"] mutableCopy] : [NSMutableArray new];
                    [list filterUsingPredicate:[NSPredicate predicateWithFormat:@"identifier != %@", pending[@"identifier"]]];
                    [list addObject:pending];
                    tasks[@"pending"] = list;
                });
                return YES;
            }
            return ((BOOL (*)(id, SEL, id, NSError **))orig)(self, submitSel, request, error);
        };
    });
}

static id<LCGuestIntentHost> (^hostProxy)(void);
static const void *kInfoKey = &kInfoKey;

#pragma mark - Delivering events (LiveProcess)

static NSMutableDictionary<NSString *, id> *runningTasks;  // token -> stand-in BGTask

/// Waits until a Bluetooth manager is on (it starts unknown), then runs the block on its queue.
static void whenPoweredOn(id manager, int triesLeft, void (^block)(void)) {
    if ([manager state] == 5 || triesLeft <= 0) {
        dispatch_queue_t queue = objc_getAssociatedObject(manager, kQueueKey) ?: dispatch_get_main_queue();
        dispatch_async(queue, block);
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        whenPoweredOn(manager, triesLeft - 1, block);
    });
}

static NSArray *peripheralsFor(id manager, NSArray<NSString *> *uuids) {
    NSMutableArray *ids = [NSMutableArray new];
    for (NSString *uuid in uuids) { NSUUID *u = [[NSUUID alloc] initWithUUIDString:uuid]; if (u) [ids addObject:u]; }
    return ids.count ? [manager retrievePeripheralsWithIdentifiers:ids] : @[];
}

static Class taskClass(BOOL processing) {
    NSString *base = processing ? @"BGProcessingTask" : @"BGAppRefreshTask";
    NSString *name = [@"LCBE" stringByAppendingString:base];
    Class cls = NSClassFromString(name);
    if (cls || !NSClassFromString(base)) return cls;
    cls = objc_allocateClassPair(NSClassFromString(base), name.UTF8String, 0);
    class_addMethod(cls, @selector(identifier), imp_implementationWithBlock(^id(id self) {
        return [objc_getAssociatedObject(self, kInfoKey) objectForKey:@"identifier"];
    }), "@@:");
    class_addMethod(cls, @selector(setTaskCompletedWithSuccess:), imp_implementationWithBlock(^(id self, BOOL success) {
        NSString *token = [objc_getAssociatedObject(self, kInfoKey) objectForKey:@"token"];
        if (!token || !runningTasks[token]) return;
        [runningTasks removeObjectForKey:token];
        [hostProxy() backgroundTaskWithToken:token didFinish:success];
    }), "v@:B");
    objc_registerClassPair(cls);
    return cls;
}

void LCBackgroundEventsGuestDeliver(NSData *data) {
    NSDictionary *event = [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil];
    NSString *type = event[@"type"];
    NSLog(@"[LCBE] guest: %@", type);
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([type isEqualToString:@"bluetooth-connection"] || [type isEqualToString:@"bluetooth-restore"]) {
            BOOL restore = [type isEqualToString:@"bluetooth-restore"];
            SEL sel = restore ? @selector(centralManager:willRestoreState:) : @selector(centralManager:connectionEventDidOccur:forPeripheral:);
            for (id manager in centralManagers.allObjects) {
                id delegate = [manager delegate];
                if (![delegate respondsToSelector:sel]) continue;
                whenPoweredOn(manager, 25, ^{
                    NSArray *peripherals = peripheralsFor(manager, restore ? event[@"peripherals"] : @[event[@"peripheral"] ?: @""]);
                    if (restore) {
                        NSString *key = symbolString("CBCentralManagerRestoredStatePeripheralsKey") ?: @"kCBRestoredPeripherals";
                        ((void (*)(id, SEL, id, NSDictionary *))objc_msgSend)(delegate, sel, manager, @{key: peripherals});
                    } else if (peripherals.firstObject) {
                        ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(delegate, sel, manager, [event[@"event"] integerValue], peripherals.firstObject);
                    }
                });
            }
        } else if ([type isEqualToString:@"location"] || [type isEqualToString:@"region"]) {
            Class locationClass = NSClassFromString(@"CLLocation"), regionClass = NSClassFromString(@"CLRegion");
            for (id manager in locationManagers.allObjects) {
                id delegate = [manager delegate];
                if ([type isEqualToString:@"location"]) {
                    NSArray *locations = [NSKeyedUnarchiver unarchivedArrayOfObjectsOfClass:locationClass fromData:event[@"locations"] error:nil];
                    if (locations.count && [delegate respondsToSelector:@selector(locationManager:didUpdateLocations:)]) {
                        ((void (*)(id, SEL, id, NSArray *))objc_msgSend)(delegate, @selector(locationManager:didUpdateLocations:), manager, locations);
                    }
                } else {
                    id region = [NSKeyedUnarchiver unarchivedObjectOfClasses:[NSSet setWithObjects:regionClass, NSClassFromString(@"CLCircularRegion"), NSClassFromString(@"CLBeaconRegion"), nil] fromData:event[@"region"] error:nil];
                    SEL sel = [event[@"enter"] boolValue] ? @selector(locationManager:didEnterRegion:) : @selector(locationManager:didExitRegion:);
                    if (region && [delegate respondsToSelector:sel]) ((void (*)(id, SEL, id, id))objc_msgSend)(delegate, sel, manager, region);
                }
            }
        } else if ([type isEqualToString:@"task"]) {
            NSArray *entry = taskHandlers[event[@"identifier"]];
            Class cls = taskClass([event[@"processing"] boolValue]);
            if (!entry || !cls) {
                [hostProxy() backgroundTaskWithToken:event[@"token"] didFinish:NO];
                return;
            }
            id task = [cls alloc];
            objc_setAssociatedObject(task, kInfoKey, @{@"identifier": event[@"identifier"], @"token": event[@"token"]}, OBJC_ASSOCIATION_RETAIN);
            if (!runningTasks) runningTasks = [NSMutableDictionary new];
            runningTasks[event[@"token"]] = task;
            void (^handler)(id) = entry[0];
            dispatch_queue_t queue = entry.count > 1 ? entry[1] : dispatch_get_global_queue(QOS_CLASS_UTILITY, 0);
            dispatch_async(queue, ^{ handler(task); });
        } else if ([type isEqualToString:@"task-expire"]) {
            id task = runningTasks[event[@"token"]];
            void (^expire)(void) = [task expirationHandler];
            if (expire) expire();
        } else if ([type isEqualToString:@"accessory-connect"]) {
            // The app may have started after the accessory connected: tell it, as iOS would have.
            dlopen("/System/Library/Frameworks/ExternalAccessory.framework/ExternalAccessory", RTLD_LAZY);
            id manager = [NSClassFromString(@"EAAccessoryManager") performSelector:@selector(sharedAccessoryManager)];
            NSString *name = symbolString("EAAccessoryDidConnectNotification"), *key = symbolString("EAAccessoryKey");
            for (id accessory in [manager valueForKey:@"connectedAccessories"]) {
                if ([[accessory valueForKey:@"connectionID"] isEqual:event[@"connectionID"]] && name && key) {
                    [NSNotificationCenter.defaultCenter postNotificationName:name object:nil userInfo:@{key: accessory}];
                }
            }
        }
    });
}

void LCBackgroundEventsGuestConnect(id<LCGuestIntentHost> (^host)(void)) {
    hostProxy = host;
}

#pragma mark - Setup

__attribute__((constructor)) static void LCBackgroundEventsInit(void) {
    NSString *path = NSBundle.mainBundle.bundlePath;
    // Apps run in LiveContainer's process or in LiveProcess; other extensions don't run apps.
    if ([path hasSuffix:@".appex"] && ![path.lastPathComponent isEqualToString:@"LiveProcess.appex"]) return;
    if (!enabledApps().count) return;
    for (NSString *framework in @[@"CoreBluetooth", @"CoreLocation", @"BackgroundTasks"]) {
        dlopen([NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", framework, framework].fileSystemRepresentation, RTLD_LAZY);
    }
    installRecorders();
}
