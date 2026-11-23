// ZaloXposed iOS - port of https://github.com/ElectroHeavenVN/ZaloXposed (AGPL-3.0)
// Pure Objective-C runtime; no Logos needed.
#import <UIKit/UIKit.h>
#import "ZXConfig.h"
#import "ZXLog.h"
#import "ZXNetwork.h"
#import "ZXHookEngine.h"
#import "ZXUI.h"
#import "ZXRecallMarker.h"

#define ZX_VERSION @"1.2.0"

__attribute__((constructor)) static void ZXInit(void)
{
    @autoreleasepool {
        @try {
            [ZXConfig registerDefaults];
            ZXLog(@"thanhthe iOS %@ loaded in %@", ZX_VERSION, [[NSBundle mainBundle] bundleIdentifier]);
            [ZXNetwork install];
            [ZXHookEngine installFromRules];
            [ZXUI install];
            [ZXRecallMarker install];

            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                              object:nil queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(NSNotification *n) {
                (void)n;
                @try {
                    [ZXHookEngine retryPending];
                } @catch (NSException *e) {
                    ZXLog(@"retryPending launch exception: %@", e.reason);
                }
            }];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                @try {
                    [ZXHookEngine retryPending];
                } @catch (NSException *e) {
                    ZXLog(@"retryPending delayed exception: %@", e.reason);
                }
            });
        } @catch (NSException *e) {
            ZXLog(@"ZXInit ctor exception: %@", e.reason);
        }
    }
}
