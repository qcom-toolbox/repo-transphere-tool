#import "RTAppDelegate.h"
#import "RTRootViewController.h"

@implementation RTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
	self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

	RTRootViewController *root = [[RTRootViewController alloc] init];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];

	self.window.rootViewController = nav;
	[self.window makeKeyAndVisible];

	return YES;
}

@end
