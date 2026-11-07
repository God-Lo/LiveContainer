//
//  LCExtensionProxy.h
//  LiveContainer (fork)
//
//  Shared by LiveContainer's extensions that run an app's extension. iOS creates the extension's
//  principal object with +alloc/-init; LC_PROXY_ALLOC hands it the app's own class instead, so the
//  app's code runs unchanged. If no app can be loaded, the proxy's own class runs and shows why.
//

#import <Foundation/Foundation.h>
#import "../../Sources/LiveContainerShared/LCGuestExtension.h"

static NSString *LCProxyError;

static inline Class LCProxyGuestClass(NSString *point, Class base) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *error = nil;
        Class found = LCGuestExtensionLoadPrincipalClass(point, &error);
        if (found && base && ![found isSubclassOfClass:base]) {
            error = [NSString stringWithFormat:@"The app's extension class %@ isn't a %@.", found, base];
            found = nil;
        }
        cls = found;
        LCProxyError = error ?: @"LiveContainer couldn't start the app's extension.";
        NSLog(@"[LCGuestExtension] %@: %@ %@", point, cls, cls ? @"" : LCProxyError);
    });
    return cls;
}

#define LC_PROXY_ALLOC(point, base) \
+ (instancetype)allocWithZone:(struct _NSZone *)zone { \
    Class cls = LCProxyGuestClass(point, base); \
    if (cls && cls != self) return [cls allocWithZone:zone]; \
    return [super allocWithZone:zone]; \
}
