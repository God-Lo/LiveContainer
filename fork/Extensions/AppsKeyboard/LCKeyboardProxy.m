//
//  LCKeyboardProxy.m
//  LiveContainer (fork)
//
//  Keyboard "LiveContainer": runs the keyboard of the app opened most recently among the apps
//  allowed to use Keyboard in LiveContainer.
//

@import UIKit;
#import "../Common/LCExtensionProxy.h"

@interface LCKeyboardProxy : UIInputViewController
@end

@implementation LCKeyboardProxy

LC_PROXY_ALLOC(kLCPointKeyboard, UIInputViewController.class)

// Only shown when no app's keyboard could be loaded.
- (void)viewDidLoad {
    [super viewDidLoad];
    UILabel *label = [UILabel new];
    label.text = LCProxyError;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    UIButton *next = [UIButton systemButtonWithImage:[UIImage systemImageNamed:@"globe"] target:self action:@selector(advanceToNextInputMode)];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[label, next]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-12],
        [self.view.heightAnchor constraintEqualToConstant:160],
    ]];
}

@end
