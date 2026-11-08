//
//  LCBackgroundEventsHost.h
//  LiveContainer (fork)
//
//  Internal: between the background-events listener (LCBackgroundEventsHost.m) and the LiveProcess
//  sessions it delivers through (LCGuestIntentHost.m).
//

#import <Foundation/Foundation.h>

/// An app running in LiveProcess for background events.
@protocol LCBEHostSession <NSObject>
/// Keeps LiveProcess running until the matching releaseHold.
- (void)hold;
- (void)releaseHold;
- (void)sendAccessoryData:(NSData *)data session:(NSString *)session;
- (void)sendAccessoryClosed:(NSString *)session;
@end

/// Starts the app (by folder) in LiveProcess if needed and delivers the event. Nil if it can't start.
id<LCBEHostSession> LCBEHostDeliver(NSString *folder, NSDictionary *event);

NSData *LCBEHostAccessoriesSnapshot(void);
void LCBEHostTaskFinished(NSString *token, BOOL success);
NSString *LCBEHostOpenAccessory(NSUInteger connectionID, NSString *protocol, id<LCBEHostSession> owner, NSString **error);
void LCBEHostAccessoryWrite(NSString *session, NSData *data);
void LCBEHostAccessoryClose(NSString *session);
void LCBEHostSessionEnded(id<LCBEHostSession> owner);
