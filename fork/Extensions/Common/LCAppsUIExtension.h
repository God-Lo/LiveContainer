//
//  LCAppsUIExtension.h
//  LiveContainer (fork)
//
//  Shared by the "LiveContainer Apps" share and action extensions. Lists the apps in LiveContainer
//  that have this kind of extension (skipped when there is only one), then runs the chosen app's own
//  extension screen inside this one. The app's screen gets this extension's context, so it reads the
//  shared items and completes or cancels the request as it would natively.
//

@import UIKit;
#import <objc/runtime.h>
#import "LCExtensionProxy.h"

@interface LCAppsUIExtensionViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
/// Subclasses return their extension point.
- (NSString *)extensionPoint;
@end

static const void *kLCHostContextKey = &kLCHostContextKey;

static NSExtensionContext *LCHostedExtensionContext(UIViewController *self, SEL _cmd) {
    return objc_getAssociatedObject(self, kLCHostContextKey);
}

@implementation LCAppsUIExtensionViewController {
    NSArray<NSDictionary *> *_apps;
    UITableView *_table;
}

- (NSString *)extensionPoint { return kLCPointShare; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    NSString *error = nil;
    _apps = LCGuestExtensionCandidates(self.extensionPoint, &error);
    if (_apps.count == 1) {
        [self openApp:_apps.firstObject];
    } else if (_apps.count == 0) {
        [self showMessage:error];
    } else {
        [self showPicker];
    }
}

- (void)showPicker {
    UINavigationBar *bar = [UINavigationBar new];
    UINavigationItem *item = [[UINavigationItem alloc] initWithTitle:@"Choose an App"];
    item.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancel)];
    bar.items = @[item];
    _table = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStyleInsetGrouped];
    _table.dataSource = self;
    _table.delegate = self;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[bar, _table]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.frame = self.view.bounds;
    stack.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:stack];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { return _apps.count; }

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = _apps[indexPath.row][kLCGEName];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView.superview removeFromSuperview];
    [self openApp:_apps[indexPath.row]];
}

- (void)openApp:(NSDictionary *)entry {
    NSString *error = nil;
    if (!LCGuestExtensionLoad(entry, &error)) return [self showMessage:error];
    UIViewController *vc = nil;
    NSString *principal = entry[kLCGEPrincipalClass];
    Class cls = principal ? NSClassFromString(principal) : nil;
    if (entry[kLCGEStoryboard]) {
        UIStoryboard *storyboard = [UIStoryboard storyboardWithName:entry[kLCGEStoryboard] bundle:NSBundle.mainBundle];
        vc = [storyboard instantiateInitialViewController];
    } else if ([cls isSubclassOfClass:UIViewController.class]) {
        vc = [cls new];
    } else if ([cls instancesRespondToSelector:@selector(beginRequestWithExtensionContext:)]) {
        // An extension without a screen: hand it the request directly.
        [(id<NSExtensionRequestHandling>)[cls new] beginRequestWithExtensionContext:self.extensionContext];
        return;
    }
    if (!vc) return [self showMessage:[NSString stringWithFormat:@"%@'s extension couldn't be opened.", entry[kLCGEName]]];

    // The app's screen reads self.extensionContext; give it this extension's context.
    objc_setAssociatedObject(vc, kLCHostContextKey, self.extensionContext, OBJC_ASSOCIATION_RETAIN);
    class_replaceMethod(vc.class, @selector(extensionContext), (IMP)LCHostedExtensionContext, "@@:");
    [self addChildViewController:vc];
    vc.view.frame = self.view.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:vc.view];
    [vc didMoveToParentViewController:self];
    self.preferredContentSize = vc.preferredContentSize;
}

- (void)showMessage:(NSString *)message {
    UILabel *label = [UILabel new];
    label.text = message ?: @"LiveContainer couldn't open the app's extension.";
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Close" forState:UIControlStateNormal];
    [close addTarget:self action:@selector(cancel) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, close]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
    ]];
}

- (void)cancel {
    [self.extensionContext cancelRequestWithError:[NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil]];
}

@end
