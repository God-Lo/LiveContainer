//
//  LCGuestIntentProtocol.h
//  LiveContainer (fork)
//
//  XPC contract between LiveContainer (host, receives Shortcuts actions for guest apps) and a guest
//  app running in LiveProcess (performs them). The host passes this endpoint to LiveProcess in the
//  extension request's userInfo under kLCGuestIntentEndpointKey.
//

#import <Foundation/Foundation.h>

static NSString *const kLCGuestIntentEndpointKey = @"lcGuestIntentEndpoint";

/// Implemented by LiveContainer, called by the guest process.
@protocol LCGuestIntentHost
- (void)guestDidFinishLaunching;
/// `result` is the NSKeyedArchiver data of the action's result object (may be nil).
- (void)actionWithToken:(NSString *)token didFinishWithResult:(NSData *)result error:(NSString *)error;

// Background events (LCBackgroundEvents.h)
/// The app finished the background task LiveContainer handed it.
- (void)backgroundTaskWithToken:(NSString *)token didFinish:(BOOL)success;
/// The app opens a session with an accessory LiveContainer reported; LiveContainer opens the real one.
- (void)openAccessory:(NSUInteger)connectionID protocol:(NSString *)protocol reply:(void (^)(NSString *session, NSString *error))reply;
- (void)accessorySession:(NSString *)session write:(NSData *)data;
- (void)closeAccessorySession:(NSString *)session;
@end

/// Implemented by the guest process, called by LiveContainer.
@protocol LCGuestIntentGuest
/// `action` is an NSKeyedArchiver archive of the LNAction LiveContainer received. The guest re-creates
/// it with the guest's own `identifier` (it may have been renamed when merged into LiveContainer).
- (void)performAction:(NSData *)action identifier:(NSString *)identifier token:(NSString *)token;

// Background events (LCBackgroundEvents.h)
/// `event` is a property list: { type, ... }, see LCBackgroundEvents.m.
- (void)deliverBackgroundEvent:(NSData *)event;
- (void)accessorySession:(NSString *)session didReceive:(NSData *)data;
- (void)accessorySessionDidClose:(NSString *)session;
@end

/// Extension request userInfo key: the accessories connected when the guest starts (property list data).
static NSString *const kLCBackgroundAccessoriesKey = @"lcBackgroundAccessories";

#ifdef __cplusplus
extern "C"
#endif
/// Called from LiveProcess main before the guest boots. No-op unless the request carries an endpoint.
void LCGuestIntentClientSetup(NSDictionary *appInfo);
