#import "RTRootViewController.h"
#import "RTRepoStore.h"
#import "RTExportServer.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static const uint16_t kServerPort = 8384;

@interface RTRootViewController () <UIDocumentPickerDelegate, NSNetServiceBrowserDelegate, NSNetServiceDelegate>

@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UITextView *repoListView;
@property (nonatomic, strong) UIButton *exportButton;
@property (nonatomic, strong) UIButton *importButton;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) RTExportServer *server;
// Held only in memory for this run of the app (never written to disk) so
// sudo doesn't have to be re-prompted for every import in the same session.
@property (nonatomic, copy) NSString *cachedSudoPassword;

@property (nonatomic, strong) NSNetServiceBrowser *browser;
@property (nonatomic, strong) NSMutableArray<NSNetService *> *foundServices;
@property (nonatomic, strong) NSNetService *resolvingService;
@property (nonatomic, weak) UIAlertController *searchingAlert;
@property (nonatomic, assign) BOOL browsingActive;

@end

@implementation RTRootViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	self.title = @"Repo Transphere Tool";
	self.view.backgroundColor = [UIColor systemBackgroundColor];

	self.countLabel = [self makeLabelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline]];
	self.countLabel.textAlignment = NSTextAlignmentCenter;

	self.repoListView = [[UITextView alloc] init];
	self.repoListView.translatesAutoresizingMaskIntoConstraints = NO;
	self.repoListView.editable = NO;
	self.repoListView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
	self.repoListView.layer.borderColor = [UIColor separatorColor].CGColor;
	self.repoListView.layer.borderWidth = 1.0;
	self.repoListView.layer.cornerRadius = 8.0;

	self.exportButton = [self makeButtonWithTitle:@"Export Repos" action:@selector(exportTapped)];
	self.importButton = [self makeButtonWithTitle:@"Import Repos" action:@selector(importTapped)];

	self.statusLabel = [self makeLabelWithFont:[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote]];
	self.statusLabel.textAlignment = NSTextAlignmentCenter;
	self.statusLabel.numberOfLines = 0;
	self.statusLabel.textColor = [UIColor secondaryLabelColor];

	UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[
		self.countLabel, self.repoListView, self.exportButton, self.importButton, self.statusLabel
	]];
	stack.axis = UILayoutConstraintAxisVertical;
	stack.spacing = 16;
	stack.translatesAutoresizingMaskIntoConstraints = NO;
	[self.view addSubview:stack];

	UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
	[NSLayoutConstraint activateConstraints:@[
		[stack.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
		[stack.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
		[stack.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
		[self.repoListView.heightAnchor constraintGreaterThanOrEqualToConstant:220],
		[self.exportButton.heightAnchor constraintEqualToConstant:50],
		[self.importButton.heightAnchor constraintEqualToConstant:50],
	]];

	[self refreshRepoList];
}

- (void)viewWillDisappear:(BOOL)animated {
	[super viewWillDisappear:animated];
	[self stopServing];
	[self stopBrowsing];
}

#pragma mark - UI helpers

- (UILabel *)makeLabelWithFont:(UIFont *)font {
	UILabel *label = [[UILabel alloc] init];
	label.font = font;
	label.textColor = [UIColor labelColor];
	return label;
}

- (UIButton *)makeButtonWithTitle:(NSString *)title action:(SEL)action {
	UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
	[button setTitle:title forState:UIControlStateNormal];
	button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
	button.backgroundColor = [UIColor secondarySystemBackgroundColor];
	button.layer.cornerRadius = 10.0;
	[button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
	return button;
}

- (void)refreshRepoList {
	NSArray<NSString *> *repos = [RTRepoStore currentRepoURLs];
	self.countLabel.text = [NSString stringWithFormat:@"%lu repo%@ configured", (unsigned long)repos.count, repos.count == 1 ? @"" : @"s"];
	self.repoListView.text = repos.count > 0 ? [repos componentsJoinedByString:@"\n"] : @"(none found)";
}

- (void)presentAlertWithTitle:(NSString *)title message:(NSString *)message {
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
	[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
	[self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Export

// This app's Data container isn't provisioned on this jailbreak (uicache
// here only refreshes the home-screen icon, confirmed via iPhone Storage
// not listing the app at all), so Documents/the document picker/the
// system share sheet's file handoff cannot be relied on. Serving the
// export over the local network sidesteps the file system entirely.
- (void)exportTapped {
	if (self.server.isRunning) {
		[self stopServing];
		return;
	}

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Export Repos"
		message:nil
		preferredStyle:UIAlertControllerStyleActionSheet];
	sheet.popoverPresentationController.sourceView = self.exportButton;
	sheet.popoverPresentationController.sourceRect = self.exportButton.bounds;

	[sheet addAction:[UIAlertAction actionWithTitle:@"Serve on Local Network (recommended)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self startServing];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Save to File" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self exportToFile];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)startServing {
	NSString *ip = [RTExportServer localWiFiIPAddress];
	if (!ip) {
		[self presentAlertWithTitle:@"No Wi-Fi Address" message:@"Couldn't find a Wi-Fi IP address for this device. Make sure Wi-Fi is on and connected."];
		return;
	}

	self.server = [[RTExportServer alloc] init];
	NSError *error = nil;
	if (![self.server startServingText:[RTRepoStore exportText] onPort:kServerPort error:&error]) {
		self.server = nil;
		[self presentAlertWithTitle:@"Couldn't Start Server" message:error.localizedDescription ?: @"Unknown error."];
		return;
	}

	NSString *deviceName = [UIDevice currentDevice].name;
	[self.server publishWithName:deviceName];

	NSString *url = [NSString stringWithFormat:@"http://%@:%u", ip, kServerPort];
	[self.exportButton setTitle:@"Stop Serving" forState:UIControlStateNormal];
	self.statusLabel.text = [NSString stringWithFormat:@"Serving at %@ as “%@”\nOn your other device, use Import > Fetch from Local Network — it should show up by name, or enter this address manually.", url, deviceName];
}

- (void)stopServing {
	if (!self.server.isRunning) return;
	[self.server stop];
	self.server = nil;
	[self.exportButton setTitle:@"Export Repos" forState:UIControlStateNormal];
	self.statusLabel.text = @"Stopped serving.";
}

// Kept as a fallback for setups where the app's Data container actually
// works; not relied on as the primary path on this device.
- (void)exportToFile {
	NSError *error = nil;
	NSURL *fileURL = [RTRepoStore writeExportFile:&error];
	if (!fileURL) {
		[self presentAlertWithTitle:@"Export Failed" message:error.localizedDescription ?: @"Unknown error."];
		return;
	}

	UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[fileURL] applicationActivities:nil];
	activity.popoverPresentationController.sourceView = self.exportButton;
	activity.popoverPresentationController.sourceRect = self.exportButton.bounds;
	[self presentViewController:activity animated:YES completion:nil];

	self.statusLabel.text = @"Exported to On My iPhone > Repo Transphere Tool.";
}

#pragma mark - Import

- (void)importTapped {
	NSArray<NSString *> *names = [RTRepoStore pendingImportFileNames];

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Import Repos"
		message:nil
		preferredStyle:UIAlertControllerStyleActionSheet];
	sheet.popoverPresentationController.sourceView = self.importButton;
	sheet.popoverPresentationController.sourceRect = self.importButton.bounds;

	[sheet addAction:[UIAlertAction actionWithTitle:@"Search Local Network…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self browseForServers];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Enter Address Manually…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self presentManualAddressPrompt];
	}]];

	for (NSString *name in names) {
		[sheet addAction:[UIAlertAction actionWithTitle:name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[self importFromTransferFolderFileNamed:name];
		}]];
	}

	[sheet addAction:[UIAlertAction actionWithTitle:@"Choose from Files…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self presentSystemFilePicker];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

	[self presentViewController:sheet animated:YES completion:nil];
}

// Browses Bonjour for other devices advertising RTBonjourServiceType (see
// -[RTExportServer publishWithName:]) for a few seconds, then shows
// whatever it found as a tappable list — manual IP entry is still offered
// alongside, in case Bonjour is blocked on this network or the other
// device is on an older version that doesn't publish.
- (void)browseForServers {
	self.foundServices = [NSMutableArray array];
	self.browsingActive = YES;

	self.browser = [[NSNetServiceBrowser alloc] init];
	self.browser.delegate = self;
	[self.browser searchForServicesOfType:RTBonjourServiceType inDomain:@"local."];

	__weak typeof(self) weakSelf = self;
	UIAlertController *searching = [UIAlertController alertControllerWithTitle:@"Searching…"
		message:@"Looking for other devices running Repo Transphere Tool on your Wi-Fi."
		preferredStyle:UIAlertControllerStyleAlert];
	[searching addAction:[UIAlertAction actionWithTitle:@"Enter Address Manually" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[weakSelf stopBrowsing];
		[weakSelf presentManualAddressPrompt];
	}]];
	[searching addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
		[weakSelf stopBrowsing];
	}]];
	self.searchingAlert = searching;
	[self presentViewController:searching animated:YES completion:nil];

	dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
		[weakSelf finishBrowsingAndShowResults];
	});
}

- (void)stopBrowsing {
	self.browsingActive = NO;
	[self.browser stop];
	self.browser = nil;
}

- (void)finishBrowsingAndShowResults {
	if (!self.browsingActive) return; // already stopped manually (Cancel / Enter Manually)
	[self stopBrowsing];

	__weak typeof(self) weakSelf = self;
	[self.searchingAlert dismissViewControllerAnimated:YES completion:^{
		[weakSelf presentBrowseResults];
	}];
}

- (void)presentBrowseResults {
	NSArray<NSNetService *> *services = self.foundServices ?: @[];

	UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Fetch from Local Network"
		message:services.count > 0 ? @"Choose a device:" : @"No devices found on your Wi-Fi. Make sure the other device tapped Export > Serve on Local Network."
		preferredStyle:UIAlertControllerStyleActionSheet];
	sheet.popoverPresentationController.sourceView = self.importButton;
	sheet.popoverPresentationController.sourceRect = self.importButton.bounds;

	for (NSNetService *service in services) {
		[sheet addAction:[UIAlertAction actionWithTitle:service.name style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
			[self resolveAndFetchService:service];
		}]];
	}
	[sheet addAction:[UIAlertAction actionWithTitle:@"Enter Address Manually…" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		[self presentManualAddressPrompt];
	}]];
	[sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

	[self presentViewController:sheet animated:YES completion:nil];
}

- (void)resolveAndFetchService:(NSNetService *)service {
	self.resolvingService = service;
	service.delegate = self;
	self.statusLabel.text = [NSString stringWithFormat:@"Connecting to %@…", service.name];
	[service resolveWithTimeout:5.0];
}

#pragma mark - NSNetServiceBrowserDelegate

- (void)netServiceBrowser:(NSNetServiceBrowser *)browser didFindService:(NSNetService *)service moreComing:(BOOL)moreComing {
	if (![self.foundServices containsObject:service]) {
		[self.foundServices addObject:service];
	}
}

#pragma mark - NSNetServiceDelegate

- (void)netServiceDidResolveAddress:(NSNetService *)sender {
	if (sender != self.resolvingService) return;
	self.resolvingService = nil;

	NSString *host = sender.hostName;
	if (!host) {
		self.statusLabel.text = nil;
		[self presentAlertWithTitle:@"Import Failed" message:@"Could not resolve that device's address."];
		return;
	}
	if ([host hasSuffix:@"."]) host = [host substringToIndex:host.length - 1];

	NSInteger port = sender.port > 0 ? sender.port : kServerPort;
	NSString *urlString = [NSString stringWithFormat:@"http://%@:%ld", host, (long)port];
	self.statusLabel.text = nil;
	[self fetchFromNetworkEntry:urlString];
}

- (void)netService:(NSNetService *)sender didNotResolve:(NSDictionary<NSString *, NSNumber *> *)errorDict {
	if (sender != self.resolvingService) return;
	self.resolvingService = nil;
	self.statusLabel.text = nil;
	[self presentAlertWithTitle:@"Import Failed" message:@"Could not connect to that device."];
}

- (void)presentManualAddressPrompt {
	UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Enter Address"
		message:@"Enter the address shown on the other device (e.g. 192.168.1.23). Both devices must be on the same Wi-Fi."
		preferredStyle:UIAlertControllerStyleAlert];

	[prompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"192.168.1.23";
		textField.keyboardType = UIKeyboardTypeURL;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];

	__weak typeof(self) weakSelf = self;
	[prompt addAction:[UIAlertAction actionWithTitle:@"Fetch" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		NSString *entry = prompt.textFields.firstObject.text ?: @"";
		[weakSelf fetchFromNetworkEntry:entry];
	}]];
	[prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

	[self presentViewController:prompt animated:YES completion:nil];
}

- (void)fetchFromNetworkEntry:(NSString *)entry {
	NSString *trimmed = [entry stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	if (trimmed.length == 0) return;

	NSString *urlString = trimmed;
	if ([urlString rangeOfString:@"://"].location == NSNotFound) {
		urlString = [NSString stringWithFormat:@"http://%@:%u", trimmed, kServerPort];
	}
	NSURL *url = [NSURL URLWithString:urlString];
	if (!url) {
		[self presentAlertWithTitle:@"Import Failed" message:@"That doesn't look like a valid address."];
		return;
	}

	self.statusLabel.text = [NSString stringWithFormat:@"Fetching from %@…", urlString];

	__weak typeof(self) weakSelf = self;
	NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
		dispatch_async(dispatch_get_main_queue(), ^{
			typeof(self) strongSelf = weakSelf;
			if (!strongSelf) return;

			if (!data) {
				[strongSelf presentAlertWithTitle:@"Import Failed" message:error.localizedDescription ?: @"Network request failed."];
				strongSelf.statusLabel.text = nil;
				return;
			}

			NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
			if (!text) {
				[strongSelf presentAlertWithTitle:@"Import Failed" message:@"Could not decode the response as text."];
				strongSelf.statusLabel.text = nil;
				return;
			}

			strongSelf.statusLabel.text = nil;
			[strongSelf processImportedText:text];
		});
	}];
	[task resume];
}

- (void)importFromTransferFolderFileNamed:(NSString *)name {
	NSError *readError = nil;
	NSString *text = [RTRepoStore contentsOfPendingImportFileNamed:name error:&readError];
	if (!text) {
		[self presentAlertWithTitle:@"Import Failed" message:readError.localizedDescription ?: @"Could not read that file."];
		return;
	}
	[self processImportedText:text];
}

// Kept as a manual fallback for setups where the picker's security-scoped
// access does work; not relied on as the primary path.
- (void)presentSystemFilePicker {
	NSArray<UTType *> *types = @[[UTType typeWithIdentifier:@"public.plain-text"], [UTType typeWithIdentifier:@"public.text"], UTTypeData];
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types];
	picker.delegate = self;
	picker.allowsMultipleSelection = NO;
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
	NSURL *fileURL = urls.firstObject;
	if (!fileURL) return;

	NSError *readError = nil;
	NSString *text = [NSString stringWithContentsOfFile:fileURL.path encoding:NSUTF8StringEncoding error:&readError];

	if (!text) {
		BOOL accessing = [fileURL startAccessingSecurityScopedResource];
		text = [NSString stringWithContentsOfURL:fileURL encoding:NSUTF8StringEncoding error:&readError];
		if (accessing) [fileURL stopAccessingSecurityScopedResource];
	}

	if (!text) {
		[self presentAlertWithTitle:@"Import Failed" message:readError.localizedDescription ?: @"Could not read the selected file."];
		return;
	}

	[self processImportedText:text];
}

- (void)processImportedText:(NSString *)text {
	NSArray<NSString *> *candidates = [RTRepoStore candidateURLsFromExportedText:text];
	if (candidates.count == 0) {
		[self presentAlertWithTitle:@"Nothing to Import" message:@"That didn't contain any repo URLs."];
		return;
	}
	[self importCandidates:candidates];
}

- (void)importCandidates:(NSArray<NSString *> *)candidates {
	[self importCandidates:candidates withPassword:self.cachedSudoPassword];
}

// Takes the password explicitly (rather than always reading
// self.cachedSudoPassword) so a mistyped password fails this one attempt
// without getting stuck cached — self.cachedSudoPassword is only updated
// once a password has actually been proven to work.
- (void)importCandidates:(NSArray<NSString *> *)candidates withPassword:(NSString *)password {
	NSError *importError = nil;
	NSArray<NSString *> *added = [RTRepoStore importRepoURLs:candidates sudoPassword:password error:&importError];

	if (!added) {
		if (importError.code == RTRepoStoreErrorPasswordRequired) {
			[self promptForSudoPasswordThenRetry:candidates];
			return;
		}
		[self presentAlertWithTitle:@"Import Failed" message:importError.localizedDescription ?: @"Unknown error."];
		return;
	}

	self.cachedSudoPassword = password;
	[self refreshRepoList];

	if (added.count == 0) {
		[self presentAlertWithTitle:@"Already Up to Date" message:@"All repos there were already configured. Nothing was added or duplicated."];
	} else {
		NSString *message = [NSString stringWithFormat:@"Added %lu new repo%@:\n\n%@\n\nOpen Sileo and refresh (or restart it) to see them.",
			(unsigned long)added.count, added.count == 1 ? @"" : @"s", [added componentsJoinedByString:@"\n"]];
		[self presentAlertWithTitle:@"Import Complete" message:message];
	}
}

// sources.list.d needs root to write to. The password is used once here
// and kept only in self.cachedSudoPassword (in-memory, this app run only)
// so later imports in the same session don't re-prompt; never persisted.
- (void)promptForSudoPasswordThenRetry:(NSArray<NSString *> *)candidates {
	UIAlertController *prompt = [UIAlertController alertControllerWithTitle:@"Root Password Needed"
		message:@"This device's sudo needs a password to write Sileo's source list. Used once here and kept only in memory for the rest of this session — never saved to disk."
		preferredStyle:UIAlertControllerStyleAlert];

	[prompt addTextFieldWithConfigurationHandler:^(UITextField *textField) {
		textField.placeholder = @"Password";
		textField.secureTextEntry = YES;
		textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
		textField.autocorrectionType = UITextAutocorrectionTypeNo;
	}];

	__weak typeof(self) weakSelf = self;
	[prompt addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
		NSString *password = prompt.textFields.firstObject.text ?: @"";
		if (password.length == 0) return;
		[weakSelf importCandidates:candidates withPassword:password];
	}]];
	[prompt addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

	[self presentViewController:prompt animated:YES completion:nil];
}

@end
