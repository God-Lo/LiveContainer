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
@end

/// Starts the app (by folder) in LiveProcess if needed and delivers the event. Nil if it can't start.
id<LCBEHostSession> LCBEHostDeliver(NSString *folder, NSDictionary *event);

void LCBEHostTaskFinished(NSString *token, BOOL success);
void LCBEHostSessionEnded(id<LCBEHostSession> owner);
