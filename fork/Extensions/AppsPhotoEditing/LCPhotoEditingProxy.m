//
//  LCPhotoEditingProxy.m
//  LiveContainer (fork)
//
//  Photos editing extension "LiveContainer": runs the photo editing extension of the app opened
//  most recently.
//

@import UIKit;
@import Photos;
@import PhotosUI;
#import "../Common/LCExtensionProxy.h"

@interface LCPhotoEditingProxy : UIViewController <PHContentEditingController>
@end

@implementation LCPhotoEditingProxy

LC_PROXY_ALLOC(kLCPointPhotoEditing, UIViewController.class)

// Below: only reached when no app's extension could be loaded.
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [UILabel new];
    label.text = LCProxyError;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.frame = CGRectInset(self.view.bounds, 24, 24);
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:label];
}
- (BOOL)canHandleAdjustmentData:(PHAdjustmentData *)adjustmentData { return NO; }
- (void)startContentEditingWithInput:(PHContentEditingInput *)contentEditingInput placeholderImage:(UIImage *)placeholderImage {}
- (void)finishContentEditingWithCompletionHandler:(void (^)(PHContentEditingOutput *))completionHandler { completionHandler(nil); }
- (BOOL)shouldShowCancelConfirmation { return NO; }
- (void)cancelContentEditing {}

@end
