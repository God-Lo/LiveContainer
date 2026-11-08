//
//  LCBackgroundEventsHost.m
//  LiveContainer (fork)
//
//  LiveContainer side of Background Events (see LCBackgroundEvents.h): makes the apps' registrations
//  under LiveContainer's own name, receives the events iOS sends LiveContainer, and delivers each to the
//  apps that registered for it.
//

#import "LCBackgroundEvents.h"
#import "LCBackgroundEventsHost.h"
#import "../../../LiveContainer/LCSharedUtils.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>

// Selectors of system classes, used through `id`.
@protocol LCBEHostSystem
+ (id)sharedScheduler;
+ (id)sharedAccessoryManager;
+ (id)UUIDWithString:(NSString *)string;
- (BOOL)registerForTaskWithIdentifier:(NSString *)identifier usingQueue:(dispatch_queue_t)queue launchHandler:(void (^)(id task))handler;
- (BOOL)submitTaskRequest:(id)request error:(NSError **)error;
- (id)initWithIdentifier:(NSString *)identifier;
- (void)setEarliestBeginDate:(NSDate *)date;
- (void)setExpirationHandler:(void (^)(void))handler;
- (void)setTaskCompletedWithSuccess:(BOOL)success;
- (NSString *)identifier;
- (id)initWithDelegate:(id)delegate queue:(dispatch_queue_t)queue options:(NSDictionary *)options;
- (void)registerForConnectionEventsWithOptions:(NSDictionary *)options;
- (NSInteger)state;
- (void)setDelegate:(id)delegate;
- (void)startMonitoringSignificantLocationChanges;
- (void)startMonitoringForRegion:(id)region;
- (NSSet *)monitoredRegions;
- (void)registerForLocalNotifications;
- (NSUInteger)connectionID;
- (NSArray<NSString *> *)protocolStrings;
@end

static NSString *symbolString(const char *name) {
    NSString *__strong *value = (NSString *__strong *)dlsym(RTLD_DEFAULT, name);
    return value ? *value : nil;
}

static NSDictionary *registryOf(NSString *folder) {
    NSData *data = [NSData dataWithContentsOfFile:[LCBackgroundEventsFolder() stringByAppendingFormat:@"/%@.plist", folder]];
    NSDictionary *registry = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:nil error:nil] : nil;
    return [registry isKindOfClass:NSDictionary.class] ? registry : @{};
}

@interface LCBEHost : NSObject
@property NSArray<NSString *> *apps;
@property NSMutableDictionary<NSString *, NSArray<NSString *> *> *accessoryProtocols;  // folder -> protocols
@property NSMutableArray *centralManagers;
@property NSMapTable *managerOwner;                                                   // manager -> folder
@property id locationManager;
@property NSMutableDictionary<NSString *, NSString *> *regionOwner;                   // region identifier -> folder
@property NSMutableDictionary<NSString *, NSArray *> *tasks;                          // token -> [BGTask, owner]
@end

static LCBEHost *host;

@implementation LCBEHost

#pragma mark Delivery

- (void)deliver:(NSDictionary *)event to:(NSString *)folder {
    NSUserDefaults *shared = [[NSUserDefaults alloc] initWithSuiteName:[LCSharedUtils appGroupID]];
    NSMutableDictionary *last = [[shared dictionaryForKey:@"LCBackgroundEventsLast"] mutableCopy] ?: [NSMutableDictionary new];
    last[folder] = NSDate.date;
    [shared setObject:last forKey:@"LCBackgroundEventsLast"];
    // iOS gives a woken app a short while; ask for enough to start the app and hand the event over.
    id app = [NSClassFromString(@"UIApplication") performSelector:@selector(sharedApplication)];
    __block NSUInteger taskId = 0;
    taskId = ((NSUInteger (*)(id, SEL, NSString *, id))objc_msgSend)(app, NSSelectorFromString(@"beginBackgroundTaskWithName:expirationHandler:"), @"Background event", ^{
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(app, NSSelectorFromString(@"endBackgroundTask:"), taskId);
    });
    LCBEHostDeliver(folder, event);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        ((void (*)(id, SEL, NSUInteger))objc_msgSend)(app, NSSelectorFromString(@"endBackgroundTask:"), taskId);
    });
}

#pragma mark Background tasks

- (void)startTasks {
    id scheduler = [NSClassFromString(@"BGTaskScheduler") sharedScheduler];
    NSArray *permitted = NSBundle.mainBundle.infoDictionary[@"BGTaskSchedulerPermittedIdentifiers"];
    if (!scheduler || !permitted.count) return;
    for (NSString *folder in self.apps) {
        NSDictionary *tasks = registryOf(folder)[@"tasks"];
        for (NSString *identifier in tasks[@"identifiers"]) {
            if (![permitted containsObject:identifier]) continue;
            [scheduler registerForTaskWithIdentifier:identifier usingQueue:dispatch_get_main_queue() launchHandler:^(id task) {
                [self runTask:task folder:folder];
            }];
        }
    }
    // Requests the apps made in LiveProcess, where the scheduler isn't available.
    for (NSString *folder in self.apps) {
        NSDictionary *registry = registryOf(folder);
        NSArray *pending = registry[@"tasks"][@"pending"];
        if (!pending.count) continue;
        for (NSDictionary *request in pending) {
            if (![permitted containsObject:request[@"identifier"]]) continue;
            Class cls = NSClassFromString([request[@"processing"] boolValue] ? @"BGProcessingTaskRequest" : @"BGAppRefreshTaskRequest");
            id taskRequest = [[cls alloc] initWithIdentifier:request[@"identifier"]];
            if (request[@"date"]) [taskRequest setEarliestBeginDate:request[@"date"]];
            NSError *error = nil;
            if (![scheduler submitTaskRequest:taskRequest error:&error]) NSLog(@"[LCBE] host: submit %@: %@", request[@"identifier"], error);
        }
        NSMutableDictionary *updated = registry.mutableCopy;
        NSMutableDictionary *tasks = [registry[@"tasks"] mutableCopy];
        [tasks removeObjectForKey:@"pending"];
        updated[@"tasks"] = tasks;
        [[NSPropertyListSerialization dataWithPropertyList:updated format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil]
            writeToFile:[LCBackgroundEventsFolder() stringByAppendingFormat:@"/%@.plist", folder] atomically:YES];
    }
}

- (void)runTask:(id)task folder:(NSString *)folder {
    NSString *token = NSUUID.UUID.UUIDString;
    BOOL processing = [task isKindOfClass:NSClassFromString(@"BGProcessingTask")];
    id<LCBEHostSession> owner = LCBEHostDeliver(folder, @{@"type": @"task", @"identifier": [task identifier], @"token": token, @"processing": @(processing)});
    if (!owner) {
        [task setTaskCompletedWithSuccess:NO];
        return;
    }
    [owner hold];
    self.tasks[token] = @[task, owner];
    [task setExpirationHandler:^{
        LCBEHostDeliver(folder, @{@"type": @"task-expire", @"token": token});
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ LCBEHostTaskFinished(token, NO); });
    }];
}

#pragma mark Bluetooth

- (void)startBluetooth {
    NSString *restoreKey = symbolString("CBCentralManagerOptionRestoreIdentifierKey");
    for (NSString *folder in self.apps) {
        NSDictionary *bluetooth = registryOf(folder)[@"bluetooth"];
        NSArray *restoreIds = bluetooth[@"restoreIds"];
        if (!restoreIds.count && ![bluetooth[@"connectionEvents"] boolValue]) continue;
        // One manager per restore ID, as the app made them, so iOS restores each to LiveContainer.
        for (id restoreId in (restoreIds.count ? restoreIds : @[NSNull.null])) {
            NSDictionary *options = [restoreId isKindOfClass:NSString.class] && restoreKey ? @{restoreKey: restoreId} : @{};
            id manager = [[NSClassFromString(@"CBCentralManager") alloc] initWithDelegate:self queue:dispatch_get_main_queue() options:options];
            if (!manager) continue;
            [self.centralManagers addObject:manager];
            [self.managerOwner setObject:folder forKey:manager];
        }
    }
}

- (void)centralManagerDidUpdateState:(id)manager {
    if ([manager state] != 5) return;
    NSString *folder = [self.managerOwner objectForKey:manager];
    NSDictionary *bluetooth = registryOf(folder)[@"bluetooth"];
    if (![bluetooth[@"connectionEvents"] boolValue]) return;
    NSMutableDictionary *options = [NSMutableDictionary new];
    NSMutableArray *services = [NSMutableArray new], *peripherals = [NSMutableArray new];
    for (NSString *uuid in bluetooth[@"services"]) { id u = [NSClassFromString(@"CBUUID") UUIDWithString:uuid]; if (u) [services addObject:u]; }
    for (NSString *uuid in bluetooth[@"peripherals"]) { NSUUID *u = [[NSUUID alloc] initWithUUIDString:uuid]; if (u) [peripherals addObject:u]; }
    NSString *servicesKey = symbolString("CBConnectionEventMatchingOptionServiceUUIDs");
    NSString *peripheralsKey = symbolString("CBConnectionEventMatchingOptionPeripheralUUIDs");
    if (services.count && servicesKey) options[servicesKey] = services;
    if (peripherals.count && peripheralsKey) options[peripheralsKey] = peripherals;
    [manager registerForConnectionEventsWithOptions:options];
}

- (void)centralManager:(id)manager willRestoreState:(NSDictionary *)state {
    NSString *folder = [self.managerOwner objectForKey:manager];
    NSString *key = symbolString("CBCentralManagerRestoredStatePeripheralsKey") ?: @"kCBRestoredPeripherals";
    NSMutableArray *uuids = [NSMutableArray new];
    for (id peripheral in state[key]) [uuids addObject:[[peripheral valueForKey:@"identifier"] UUIDString] ?: @""];
    if (folder) [self deliver:@{@"type": @"bluetooth-restore", @"peripherals": uuids} to:folder];
}

- (void)centralManager:(id)manager connectionEventDidOccur:(NSInteger)event forPeripheral:(id)peripheral {
    NSString *folder = [self.managerOwner objectForKey:manager];
    NSString *uuid = [[peripheral valueForKey:@"identifier"] UUIDString];
    if (folder && uuid) [self deliver:@{@"type": @"bluetooth-connection", @"event": @(event), @"peripheral": uuid} to:folder];
}

#pragma mark Location

- (void)startLocation {
    BOOL significant = NO;
    NSMutableArray *regions = [NSMutableArray new];
    for (NSString *folder in self.apps) {
        NSDictionary *location = registryOf(folder)[@"location"];
        if ([location[@"significant"] boolValue]) significant = YES;
        NSDictionary *archived = location[@"regions"];
        for (NSString *identifier in archived) {
            NSSet *classes = [NSSet setWithObjects:NSClassFromString(@"CLRegion"), NSClassFromString(@"CLCircularRegion"), NSClassFromString(@"CLBeaconRegion"), nil];
            id region = [NSKeyedUnarchiver unarchivedObjectOfClasses:classes fromData:archived[identifier] error:nil];
            if (!region) continue;
            self.regionOwner[identifier] = folder;
            [regions addObject:region];
        }
    }
    if (!significant && !regions.count) return;
    self.locationManager = [NSClassFromString(@"CLLocationManager") new];
    [self.locationManager setDelegate:self];
    if (significant) [self.locationManager startMonitoringSignificantLocationChanges];
    NSSet *monitored = [[self.locationManager monitoredRegions] valueForKey:@"identifier"];
    for (id region in regions) {
        if (![monitored containsObject:[region identifier]]) [self.locationManager startMonitoringForRegion:region];
    }
}

- (void)locationManager:(id)manager didUpdateLocations:(NSArray *)locations {
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:locations requiringSecureCoding:YES error:nil];
    if (!archived) return;
    for (NSString *folder in self.apps) {
        if ([registryOf(folder)[@"location"][@"significant"] boolValue]) [self deliver:@{@"type": @"location", @"locations": archived} to:folder];
    }
}

- (void)region:(id)region entered:(BOOL)entered {
    NSString *folder = self.regionOwner[[region identifier]];
    NSData *archived = [NSKeyedArchiver archivedDataWithRootObject:region requiringSecureCoding:YES error:nil];
    if (folder && archived) [self deliver:@{@"type": @"region", @"enter": @(entered), @"region": archived} to:folder];
}
- (void)locationManager:(id)manager didEnterRegion:(id)region { [self region:region entered:YES]; }
- (void)locationManager:(id)manager didExitRegion:(id)region { [self region:region entered:NO]; }

#pragma mark Accessories

- (void)startAccessories {
    for (NSString *folder in self.apps) {
        bool isShared = false;
        NSBundle *bundle = [LCSharedUtils findBundleWithBundleId:folder isSharedAppOut:&isShared];
        NSArray *protocols = bundle.infoDictionary[@"UISupportedExternalAccessoryProtocols"];
        if (protocols.count) self.accessoryProtocols[folder] = protocols;
    }
    if (!self.accessoryProtocols.count) return;
    id manager = [NSClassFromString(@"EAAccessoryManager") sharedAccessoryManager];
    [manager registerForLocalNotifications];
    NSString *key = symbolString("EAAccessoryKey");
    for (NSString *name in @[@"EAAccessoryDidConnectNotification", @"EAAccessoryDidDisconnectNotification"]) {
        BOOL connected = [name containsString:@"Connect"] && ![name containsString:@"Disconnect"];
        [NSNotificationCenter.defaultCenter addObserverForName:symbolString(name.UTF8String) object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            id accessory = key ? note.userInfo[key] : nil;
            if (!accessory) return;
            for (NSString *folder in self.accessoryProtocols) {
                if (![[NSSet setWithArray:self.accessoryProtocols[folder]] intersectsSet:[NSSet setWithArray:[accessory protocolStrings]]]) continue;
                [self deliver:@{@"type": connected ? @"accessory-connect" : @"accessory-disconnect", @"connectionID": @([accessory connectionID])} to:folder];
            }
        }];
    }
}

@end

#pragma mark - Calls from the sessions

void LCBEHostTaskFinished(NSString *token, BOOL success) {
    NSArray *entry = host.tasks[token];
    if (!entry) return;
    [host.tasks removeObjectForKey:token];
    [entry[0] setTaskCompletedWithSuccess:success];
    [(id<LCBEHostSession>)entry[1] releaseHold];
}

void LCBEHostSessionEnded(id<LCBEHostSession> owner) {
    for (NSString *token in host.tasks.allKeys) {
        if (host.tasks[token][1] == owner) LCBEHostTaskFinished(token, NO);
    }
}

void LCBackgroundEventsHostStart(NSDictionary *launchOptions) {
    NSString *folder = LCBackgroundEventsFolder();
    NSArray *apps = folder ? [NSArray arrayWithContentsOfFile:[folder stringByAppendingPathComponent:@"apps.plist"]] : nil;
    if (!apps.count || host) return;
    for (NSString *framework in @[@"CoreBluetooth", @"CoreLocation", @"BackgroundTasks", @"ExternalAccessory"]) {
        dlopen([NSString stringWithFormat:@"/System/Library/Frameworks/%@.framework/%@", framework, framework].fileSystemRepresentation, RTLD_LAZY);
    }
    host = [LCBEHost new];
    host.apps = apps;
    host.accessoryProtocols = [NSMutableDictionary new];
    host.centralManagers = [NSMutableArray new];
    host.managerOwner = [NSMapTable strongToStrongObjectsMapTable];
    host.regionOwner = [NSMutableDictionary new];
    host.tasks = [NSMutableDictionary new];
    NSLog(@"[LCBE] host: listening for %@ (launch options %@)", apps, launchOptions.allKeys);
    [host startTasks];
    [host startBluetooth];
    [host startLocation];
    [host startAccessories];
}
