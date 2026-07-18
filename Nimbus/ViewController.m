#import "ViewController.h"
#import <DJISDK/DJISDK.h>

@interface ViewController ()<DJISDKManagerDelegate>
@end

@implementation ViewController

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self registerApp];
}

- (void)registerApp {
    [DJISDKManager registerAppWithDelegate:self];
}

#pragma mark - DJISDKManagerDelegate Methods

- (void)appRegisteredWithError:(NSError *)error {
    NSString *message = @"Register App Succeeded!";
    if (error) {
        message = @"Register App Failed! Please enter your App Key in the plist file and check the network.";
    } else {
        NSLog(@"registerAppSuccess");
    }
    
    [self showAlertViewWithTitle:@"Register App" withMessage:message];
}

- (void)showAlertViewWithTitle:(NSString *)title withMessage:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil];
    [alert addAction:okAction];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)productConnected:(DJIBaseProduct *)product {
    NSLog(@"Product connected: %@", product);
}

- (void)productDisconnected {
    NSLog(@"Product disconnected");
}

@end
