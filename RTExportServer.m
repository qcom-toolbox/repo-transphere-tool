#import "RTExportServer.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <unistd.h>
#import <netdb.h>

NSString *const RTExportServerErrorDomain = @"com.qcom-toolbox.repo-transphere-tool.server";
NSString *const RTBonjourServiceType = @"_repotransphere._tcp.";

@interface RTExportServer () <NSNetServiceDelegate>
@property (nonatomic, assign) int listenSocket;
@property (nonatomic, copy) NSString *servedText;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic, assign) BOOL running;
@property (nonatomic, assign) uint16_t port;
@property (nonatomic, strong) NSNetService *netService;
@end

@implementation RTExportServer

- (BOOL)isRunning {
	return self.running;
}

- (BOOL)startServingText:(NSString *)text onPort:(uint16_t)port error:(NSError **)error {
	[self stop];
	self.servedText = text;
	self.port = port;

	int sock = socket(AF_INET, SOCK_STREAM, 0);
	if (sock < 0) {
		if (error) *error = [NSError errorWithDomain:RTExportServerErrorDomain code:errno userInfo:@{NSLocalizedDescriptionKey: @"Could not create a network socket."}];
		return NO;
	}

	int yes = 1;
	setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));

	struct sockaddr_in addr;
	memset(&addr, 0, sizeof(addr));
	addr.sin_family = AF_INET;
	addr.sin_addr.s_addr = INADDR_ANY;
	addr.sin_port = htons(port);

	if (bind(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
		int savedErrno = errno;
		close(sock);
		if (error) *error = [NSError errorWithDomain:RTExportServerErrorDomain code:savedErrno userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not bind to port %u: %s", port, strerror(savedErrno)]}];
		return NO;
	}

	if (listen(sock, 8) < 0) {
		int savedErrno = errno;
		close(sock);
		if (error) *error = [NSError errorWithDomain:RTExportServerErrorDomain code:savedErrno userInfo:@{NSLocalizedDescriptionKey: @"Could not listen on socket."}];
		return NO;
	}

	self.listenSocket = sock;
	self.running = YES;

	self.queue = dispatch_queue_create("com.qcom-toolbox.repo-transphere-tool.server", DISPATCH_QUEUE_SERIAL);
	__weak typeof(self) weakSelf = self;
	dispatch_async(self.queue, ^{
		[weakSelf acceptLoop];
	});

	return YES;
}

- (void)acceptLoop {
	while (self.running) {
		struct sockaddr_in clientAddr;
		socklen_t clientLen = sizeof(clientAddr);
		int client = accept(self.listenSocket, (struct sockaddr *)&clientAddr, &clientLen);
		if (client < 0) {
			if (!self.running) break;
			continue;
		}
		[self handleClient:client];
	}
}

- (void)handleClient:(int)clientSocket {
	// We don't care what was requested; drain whatever the client sends
	// and always answer with the same plain-text body.
	char buf[2048];
	recv(clientSocket, buf, sizeof(buf) - 1, 0);

	NSData *body = [self.servedText dataUsingEncoding:NSUTF8StringEncoding];
	NSString *headers = [NSString stringWithFormat:
		@"HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: %lu\r\nConnection: close\r\n\r\n",
		(unsigned long)body.length];
	NSData *headerData = [headers dataUsingEncoding:NSUTF8StringEncoding];

	send(clientSocket, headerData.bytes, headerData.length, 0);
	send(clientSocket, body.bytes, body.length, 0);
	close(clientSocket);
}

- (void)publishWithName:(NSString *)name {
	[self.netService stop];
	self.netService = [[NSNetService alloc] initWithDomain:@"local." type:RTBonjourServiceType name:name port:self.port];
	self.netService.delegate = self;
	[self.netService publish];
}

- (void)stop {
	self.running = NO;
	if (self.listenSocket > 0) {
		shutdown(self.listenSocket, SHUT_RDWR);
		close(self.listenSocket);
		self.listenSocket = 0;
	}
	[self.netService stop];
	self.netService = nil;
}

- (void)dealloc {
	[self stop];
}

+ (nullable NSString *)localWiFiIPAddress {
	NSString *address = nil;
	struct ifaddrs *interfaces = NULL;
	if (getifaddrs(&interfaces) == 0) {
		for (struct ifaddrs *ifa = interfaces; ifa; ifa = ifa->ifa_next) {
			if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
			NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
			if ([name isEqualToString:@"en0"]) {
				char host[NI_MAXHOST];
				struct sockaddr_in *addrIn = (struct sockaddr_in *)ifa->ifa_addr;
				if (inet_ntop(AF_INET, &(addrIn->sin_addr), host, sizeof(host))) {
					address = [NSString stringWithUTF8String:host];
				}
				break;
			}
		}
		freeifaddrs(interfaces);
	}
	return address;
}

@end
