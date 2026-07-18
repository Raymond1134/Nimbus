#import "ViewController.h"
#import <DJISDK/DJISDK.h>

@interface ViewController ()<DJISDKManagerDelegate>
@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self registerApp];
}

- (void)registerApp {
    // Register the DJI SDK with your App Key
    [DJISDKManager registerAppWithDelegate:self];
}

#pragma mark - DJISDKManagerDelegate Methods

- (void)appRegisteredWithError:(NSError *)error {
    if (error) {
        NSLog(@"App registration failed: %@", error.localizedDescription);
    } else {
        NSLog(@"App registered successfully");
        [DJISDKManager startConnectionToProduct];
    }
}

- (void)productConnected:(DJIBaseProduct *)product {
    NSLog(@"Product connected: %@", product);
}

- (void)productDisconnected {
    NSLog(@"Product disconnected");
}

@end
