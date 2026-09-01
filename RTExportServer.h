#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const RTExportServerErrorDomain;

// Bonjour service type this app advertises/browses under, so the other
// device can find a running server without the user typing an IP.
extern NSString *const RTBonjourServiceType;

// A minimal single-purpose HTTP server: every request gets the same
// plain-text body back. Exists purely to move the exported repo list
// between two devices over the local network, bypassing the file system
// entirely (this app's Data container is not provisioned on this
// jailbreak, so file-based transfer via Documents/the document picker
// isn't reliable here).
@interface RTExportServer : NSObject

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, readonly) uint16_t port;

- (BOOL)startServingText:(NSString *)text onPort:(uint16_t)port error:(NSError **)error;

// Advertises this server via Bonjour under RTBonjourServiceType so the
// other device's search finds it by name instead of needing an IP typed
// in. Call after startServingText:onPort:error: succeeds; best-effort —
// if Bonjour publishing fails, manual IP entry still works as a fallback.
- (void)publishWithName:(NSString *)name;

- (void)stop;

// The device's own Wi-Fi (en0) IPv4 address, or nil if not on Wi-Fi.
+ (nullable NSString *)localWiFiIPAddress;

@end

NS_ASSUME_NONNULL_END
