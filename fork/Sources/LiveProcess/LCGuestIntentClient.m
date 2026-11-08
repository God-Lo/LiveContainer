//
//  LCGuestIntentClient.m
//  LiveContainer (fork)
//
//  Guest side of Shortcuts forwarding: runs inside LiveProcess with the guest app loaded, so the
//  guest's AppIntent types resolve, and performs actions LiveContainer forwards to it through the
//  same private App Intents entry point upstream uses for SideStore (LNAppContext).
//

#import "LCGuestIntentProtocol.h"
#import <dlfcn.h>

@interface LCGILNAction : NSObject
- (instancetype)initWithIdentifier:(NSString *)identifier mangledTypeName:(NSString *)mangledTypeName
                     openAppWhenRun:(BOOL)openAppWhenRun parameters:(NSArray *)parameters;
@end
@interface LCGILNActionExecutorOptions : NSObject
@property(nonatomic, copy) NSString *clientLabel;
@property(nonatomic) NSInteger kind;
@property(nonatomic) BOOL donateToTranscript;
@end
@interface LCGILNAppContext : NSObject
- (void)performAction:(id)action options:(id)options reportingProgress:(NSProgress *)progress
             delegate:(id)delegate auditToken:(audit_token_t *)auditToken
    completionHandler:(void (^)(id result, NSError *error))completion;
@end

@interface LCGuestIntentClient : NSObject <LCGuestIntentGuest>
@property NSXPCConnection *connection;
@end

@implementation LCGuestIntentClient

- (id<LCGuestIntentHost>)host {
    return [self.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        NSLog(@"[LC] guest intent host unreachable: %@", error);
    }];
}

- (void)appDidFinishLaunching:(NSNotification *)note {
    NSLog(@"[LCGI] guest: did finish launching");
    [self.host guestDidFinishLaunching];
}

- (void)performAction:(NSData *)actionData identifier:(NSString *)identifier token:(NSString *)token {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self runAction:actionData identifier:identifier token:token];
    });
}

- (void)runAction:(NSData *)actionData identifier:(NSString *)identifier token:(NSString *)token {
    NSLog(@"[LCGI] guest: running %@", identifier);
    dlopen("/System/Library/Frameworks/AppIntents.framework/AppIntents", RTLD_LAZY);
    Class actionClass = NSClassFromString(@"LNAction");
    Class optionsClass = NSClassFromString(@"LNActionExecutorOptions");
    Class contextClass = NSClassFromString(@"LNAppContext");
    if (!actionClass || !optionsClass || !contextClass) {
        [self.host actionWithToken:token didFinishWithResult:nil error:@"App Intents private classes are unavailable on this iOS version."];
        return;
    }
    NSError *error = nil;
    NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:actionData error:&error];
    unarchiver.requiresSecureCoding = NO;
    id received = [unarchiver decodeObjectForKey:NSKeyedArchiveRootObjectKey];
    if (!received) {
        [self.host actionWithToken:token didFinishWithResult:nil error:[NSString stringWithFormat:@"Could not decode the action: %@", error]];
        return;
    }
    NSString *mangled = [received valueForKey:@"mangledTypeName"];
    NSArray *parameters = [received valueForKey:@"parameters"] ?: @[];
    LCGILNAction *action = [[actionClass alloc] initWithIdentifier:identifier mangledTypeName:mangled
                                                    openAppWhenRun:NO parameters:parameters];
    LCGILNActionExecutorOptions *options = [optionsClass new];
    options.clientLabel = @"LiveContainerGuestIntent";
    options.kind = 2;
    options.donateToTranscript = NO;
    audit_token_t auditToken = {};
    LCGILNAppContext *context = [contextClass new];
    [context performAction:action options:options reportingProgress:[NSProgress progressWithTotalUnitCount:1]
                  delegate:nil auditToken:&auditToken completionHandler:^(id result, NSError *err) {
        NSLog(@"[LCGI] guest: %@ finished result=%@ error=%@", identifier, result, err);
        NSData *resultData = nil;
        if (result) {
            resultData = [NSKeyedArchiver archivedDataWithRootObject:result requiringSecureCoding:NO error:nil];
        }
        [self.host actionWithToken:token didFinishWithResult:resultData error:err.localizedDescription];
    }];
}

@end

static LCGuestIntentClient *sharedClient;

void LCGuestIntentClientSetup(NSDictionary *appInfo) {
    NSXPCListenerEndpoint *endpoint = appInfo[kLCGuestIntentEndpointKey];
    if (![endpoint isKindOfClass:NSXPCListenerEndpoint.class]) return;
    NSLog(@"[LCGI] guest: setting up for %@", appInfo[@"selected"]);
    sharedClient = [LCGuestIntentClient new];
    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithListenerEndpoint:endpoint];
    connection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCGuestIntentGuest)];
    connection.exportedObject = sharedClient;
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(LCGuestIntentHost)];
    sharedClient.connection = connection;
    [connection activate];
    [NSNotificationCenter.defaultCenter addObserver:sharedClient selector:@selector(appDidFinishLaunching:)
                                               name:@"UIApplicationDidFinishLaunchingNotification" object:nil];
}
