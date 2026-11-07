//
//  SideStoreHooks.m
//  LiveContainer
//
//  Created by s s on 2026/8/6.
//
#include "../LiveContainer/utils.h"
#include "../LiveContainer/LCSharedUtils.h"
#include "XPCServer.h"
#import <sys/sysctl.h>
@import UserNotifications;
@import UIKit;

@interface LCAuthorizedNotificationSettings : UNNotificationSettings
@end

@implementation LCAuthorizedNotificationSettings

- (UNAuthorizationStatus)authorizationStatus {
    return UNAuthorizationStatusAuthorized;
}

@end

static NSMutableDictionary<NSString *, UIWindow *> *SSVersionWindows;
static id SSSceneObserver;

@interface PassthroughWindow : UIWindow
@end

@implementation PassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    return nil;
}

@end

@implementation UNUserNotificationCenter(SideStoreHooks)

- (void)lc_addNotificationRequest:(UNNotificationRequest*)request
            withCompletionHandler:(void (^)(NSError* error))completionHandler {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server addNotificationRequest:request];
    if (completionHandler) {
        completionHandler(nil);
    }
}

- (void)lc_removePendingNotificationRequestsWithIdentifiers:(NSArray<NSString*>*)identifiers {
    LiveProcessSideStoreHandler* handler = [PrivClass(LiveProcessSideStoreHandler) shared];
    [handler.server removePendingNotificationRequestsWithIdentifiers:identifiers];
}

- (void)lc_getNotificationSettingsWithCompletionHandler:(void (^)(UNNotificationSettings* settings))completionHandler {
    if (!completionHandler) {
        return;
    }

    UNNotificationSettings* settings = class_createInstance(LCAuthorizedNotificationSettings.class, 0);
    completionHandler(settings);
}

@end

@implementation NSBundle(SideStoreHooks)

+ (NSString*)hook_appbundleIdentifier {
    return @"com.kdt.livecontainer";
}

+ (NSString*)hook_storeAppBundleIdentifier {
    return @"com.kdt.livecontainer";
}

- (NSString*)hook_altstoreAppGroup {
    return LCSharedUtils.appGroupID;
}

+ (NSString*)hook_baseAltStoreAppGroupID {
    return @"group.com.SideStore.SideStore";
}

+ (NSBundle*)hook_activeBundle {
    if (!NSUserDefaults.isLiveProcess) return NSUserDefaults.lcMainBundle;
    
    static NSBundle* lcAppBundle = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        lcAppBundle = [NSBundle bundleWithURL: NSUserDefaults.lcMainBundle.bundleURL.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent];
    });
    return lcAppBundle;
}

@end

NSURL* SideStoreSource_hook_altStoreSourceURL(id self, SEL cmd) {
    static NSURL* sourceURL = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        // fork: the built-in source is this fork's source, so LiveContainer updates come from it
        sourceURL = [NSURL URLWithString:@"https://raw.githubusercontent.com/God-Lo/LiveContainer/main/source.json"];
    });
    return sourceURL;
}
// fork: fetch this fork's source through GitHub's API, which serves the latest commit (the plain link can
// keep serving an older copy for minutes), so SideStore sees a new release as soon as LiveContainer's own
// update check does.
static NSURLSessionDataTask *(*SideStoreSession_orig_dataTask)(id self, SEL cmd, NSURLRequest *request, id completion);
static NSURLSessionDataTask *SideStoreSession_hook_dataTask(id self, SEL cmd, NSURLRequest *request, id completion) {
    NSURL *source = SideStoreSource_hook_altStoreSourceURL(nil, nil);
    if ([request.URL.host isEqualToString:source.host] && [request.URL.path isEqualToString:source.path]) {
        NSMutableURLRequest *fresh = [request mutableCopy];
        fresh.URL = [NSURL URLWithString:@"https://api.github.com/repos/God-Lo/LiveContainer/contents/source.json"];
        [fresh setValue:@"application/vnd.github.raw" forHTTPHeaderField:@"Accept"];
        fresh.cachePolicy = NSURLRequestReloadIgnoringLocalAndRemoteCacheData;
        request = fresh;
    }
    return SideStoreSession_orig_dataTask(self, cmd, request, completion);
}

// fork: LiveContainer's update prompt opens SideStore on My Apps, where the user taps Update.
static void (*SideStoreTabBar_orig_viewDidAppear)(UITabBarController *self, SEL cmd, BOOL animated);
static void SideStoreTabBar_hook_viewDidAppear(UITabBarController *self, SEL cmd, BOOL animated) {
    SideStoreTabBar_orig_viewDidAppear(self, cmd, animated);
    NSUserDefaults *shared = NSUserDefaults.lcSharedDefaults;
    if ([shared boolForKey:@"LCSideStoreOpenMyApps"] && self.viewControllers.count > 3) {
        [shared removeObjectForKey:@"LCSideStoreOpenMyApps"];
        self.selectedIndex = 3;  // News, Sources, Browse, My Apps, Settings
    }
}

// fork: LiveContainer's own update check compares builds (e.g. 3.8.11.4 > 3.8.11.3). SideStore compares
// versions only, and can't tell which build was installed from a file.
static BOOL (*SideStoreInstalledApp_orig_hasUpdate)(id self, SEL cmd);
static BOOL SideStoreInstalledApp_hook_hasUpdate(id self, SEL cmd) {
    @try {
        if ([[self valueForKey:@"bundleIdentifier"] isEqualToString:@"com.kdt.livecontainer"]) {
            id latest = [self valueForKeyPath:@"storeApp.latestVersion"];
            NSString *latestBuild = [latest valueForKey:@"buildVersion"] ?: [latest valueForKey:@"version"];
            NSString *installed = NSUserDefaults.lcMainBundle.infoDictionary[@"CFBundleVersion"];
            return latestBuild && installed && [latestBuild compare:installed options:NSNumericSearch] == NSOrderedDescending;
        }
    } @catch (NSException *e) {}
    return SideStoreInstalledApp_orig_hasUpdate(self, cmd);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wundeclared-selector"
void (*SideStoreMyAppsViewController_orig_viewDidload)(UICollectionViewController* self, SEL cmd) = nil;
void SideStoreMyAppsViewController_hook_viewDidload(UICollectionViewController* self, SEL cmd) {
    if(!SideStoreMyAppsViewController_orig_viewDidload) return;
    SideStoreMyAppsViewController_orig_viewDidload(self, cmd);
    
    UIImage *escapeImage = [UIImage systemImageNamed:@"escape"];
    UIBarButtonItem *escapeItem = [[UIBarButtonItem alloc] initWithImage:escapeImage
                                                                   style:UIBarButtonItemStylePlain
                                                                  target:self
                                                                  action:@selector(escapeButtonTapped:)];
        
    NSMutableArray* oldToolBarItems = [self.navigationItem.leftBarButtonItems mutableCopy];
    [oldToolBarItems addObject:escapeItem];
    self.navigationItem.leftBarButtonItems = oldToolBarItems;
}

void SideStoreMyAppsViewController_hook_escapeButtonTapped(UICollectionViewController* self, SEL cmd, id target) {
    [LCSharedUtils launchToGuestAppWithClassicMode:0];
}





static void SSInstallVersionWindow(UIWindowScene *windowScene)
{
    NSString *identifier = windowScene.session.persistentIdentifier;
    if (identifier.length == 0 || SSVersionWindows[identifier] != nil) {
        return;
    }
    
    
    NSString* LCVersion = [NSString stringWithFormat:@"%@-%@",
                         NSUserDefaults.lcMainBundle.infoDictionary[@"CFBundleShortVersionString"],
                         NSUserDefaults.lcMainBundle.infoDictionary[@"LCVersionInfo"]];
    
    NSString* SSVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    
    NSString *osVersion = [[UIDevice currentDevice] systemVersion];
    size_t size = 32;
    char iosBuild[32];
    sysctlbyname("kern.osversion", iosBuild, &size, NULL, 0);
    bool isPhone = UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
    NSString* allVersionString = [NSString stringWithFormat:isPhone ? @"LC %@, SS %@\niOS %@ (%s)" : @"LC %@, SS %@, iOS %@ (%s)", LCVersion, SSVersion, osVersion, iosBuild];

    UILabel* versionLabel = [UILabel new];
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
    versionLabel.font = [UIFont systemFontOfSize:9 weight:UIFontWeightRegular];
    versionLabel.textColor = UIColor.labelColor;
    versionLabel.textAlignment = NSTextAlignmentCenter;
    versionLabel.userInteractionEnabled = NO;
    versionLabel.text = allVersionString;
    versionLabel.numberOfLines = 0;
    versionLabel.lineBreakMode = NSLineBreakByWordWrapping;
    
    UIViewController *rootController = [[UIViewController alloc] init];
    rootController.view.backgroundColor = UIColor.clearColor;
    [rootController.view addSubview:versionLabel];
    
    if(windowScene.keyWindow.safeAreaInsets.bottom == 0) {
        // old devices with no bottom safe area
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.topAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.topAnchor]
        ]];
    } else {
        // new devices
        [NSLayoutConstraint activateConstraints:@[
            [versionLabel.centerXAnchor constraintEqualToAnchor:rootController.view.centerXAnchor],
            [versionLabel.bottomAnchor constraintEqualToAnchor: rootController.view.safeAreaLayoutGuide.bottomAnchor
                                                      constant: isPhone ? 22 : 0]
        ]];
    }
    PassthroughWindow *window = [[PassthroughWindow alloc] initWithWindowScene:windowScene];

    window.rootViewController = rootController;
    window.backgroundColor = UIColor.clearColor;

    window.windowLevel = UIWindowLevelAlert;

    window.hidden = NO;

    SSVersionWindows[identifier] = window;
}


void installSideStoreHooks(void) {

    swizzleClassMethod(NSBundle.class, @selector(appbundleIdentifier), @selector(hook_appbundleIdentifier));
    swizzleClassMethod(NSBundle.class, @selector(storeAppBundleIdentifier), @selector(hook_storeAppBundleIdentifier));
    swizzle(NSBundle.class, @selector(altstoreAppGroup), @selector(hook_altstoreAppGroup));
    swizzleClassMethod(NSBundle.class, @selector(activeBundle), @selector(hook_activeBundle));
    swizzleClassMethod(NSBundle.class, @selector(baseAltStoreAppGroupID), @selector(hook_baseAltStoreAppGroupID));
    
    // replace altStoreSourceURL
    Method altStoreSourceURLMethod = class_getClassMethod(PrivClass(Source), @selector(altStoreSourceURL));
    method_setImplementation(altStoreSourceURLMethod, (IMP)SideStoreSource_hook_altStoreSourceURL);

    // fork: fresh source fetches, and opening on My Apps when LiveContainer asks
    Method dataTaskMethod = class_getInstanceMethod(NSURLSession.class, @selector(dataTaskWithRequest:completionHandler:));
    SideStoreSession_orig_dataTask = (void *)method_getImplementation(dataTaskMethod);
    method_setImplementation(dataTaskMethod, (IMP)SideStoreSession_hook_dataTask);
    Method appearMethod = class_getInstanceMethod(UITabBarController.class, @selector(viewDidAppear:));
    SideStoreTabBar_orig_viewDidAppear = (void *)method_getImplementation(appearMethod);
    method_setImplementation(appearMethod, (IMP)SideStoreTabBar_hook_viewDidAppear);
    
    // fork: updates of LiveContainer itself are found by build number
    Method hasUpdateMethod = class_getInstanceMethod(PrivClass(InstalledApp), @selector(hasUpdate));
    if (hasUpdateMethod) {
        SideStoreInstalledApp_orig_hasUpdate = (BOOL (*)(id, SEL))method_getImplementation(hasUpdateMethod);
        method_setImplementation(hasUpdateMethod, (IMP)SideStoreInstalledApp_hook_hasUpdate);
    }
    
    // fork: always keep app extensions signed with the main profile (one App ID), without asking.
    // Choosing Remove All or Keep All in SideStore's User Customizations still sticks; Prompt User doesn't.
    NSString *extensionChoice = [NSUserDefaults.standardUserDefaults stringForKey:@"customizeAppExtensions"];
    if (!extensionChoice || [extensionChoice isEqualToString:@"prompt-user"]) {
        [NSUserDefaults.standardUserDefaults setObject:@"use-main-profile" forKey:@"customizeAppExtensions"];
    }

    if (!NSUserDefaults.isLiveProcess) {
        // add escape button
        Method viewDidLoadMethod = class_getInstanceMethod(PrivClass(MyAppsViewController), @selector(viewDidLoad));
        SideStoreMyAppsViewController_orig_viewDidload = (void (*)(UICollectionViewController *, SEL))method_getImplementation(viewDidLoadMethod);
        method_setImplementation(viewDidLoadMethod, (IMP)SideStoreMyAppsViewController_hook_viewDidload);
        class_addMethod(PrivClass(MyAppsViewController), @selector(escapeButtonTapped:), (IMP)SideStoreMyAppsViewController_hook_escapeButtonTapped, "v@:@");
        
        // add version number
        SSVersionWindows = [NSMutableDictionary dictionary];

        SSSceneObserver =
        [NSNotificationCenter.defaultCenter addObserverForName:UISceneDidActivateNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *notification) {
            UIScene *scene = notification.object;
            
            if ([scene isKindOfClass:UIWindowScene.class]) {
                SSInstallVersionWindow((UIWindowScene *)scene);
            }
        }];
        
        
        
    }
    

}
#pragma clang diagnostic pop

void installSideStoreNotificationHooks(void) {
    swizzle(UNUserNotificationCenter.class,
            @selector(addNotificationRequest:withCompletionHandler:),
            @selector(lc_addNotificationRequest:withCompletionHandler:));
    swizzle(UNUserNotificationCenter.class,
            @selector(removePendingNotificationRequestsWithIdentifiers:),
            @selector(lc_removePendingNotificationRequestsWithIdentifiers:));
    swizzle(UNUserNotificationCenter.class,
            @selector(getNotificationSettingsWithCompletionHandler:),
            @selector(lc_getNotificationSettingsWithCompletionHandler:));
}
