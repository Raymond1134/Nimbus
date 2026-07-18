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
    // Load App Key from Config.plist
    NSString *configPath = [[NSBundle mainBundle] pathForResource:@"Config" ofType:@"plist"];
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:configPath];
    NSString *appKey = config[@"DJI_APP_KEY"];
    
    if (!appKey || [appKey containsString:@"YOUR_DJI_APP_KEY"]) {
        NSLog(@"Error: DJI App Key not configured in Config.plist");
        return;
    }
    
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
