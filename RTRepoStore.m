#import "RTRepoStore.h"
#import <unistd.h>
#import <spawn.h>
#import <sys/wait.h>

extern char **environ;

// sudo's own messages follow the process's locale — this device runs
// French, which is why "a password is required" came back as "il est
// nécessaire de saisir un mot de passe" and the English-only substring
// check below missed it. Force the spawned sudo's locale to C so its
// output is always in a predictable language we can actually parse.
static char **RTEnvironWithCLocale(void) {
	NSMutableArray<NSString *> *pairs = [NSMutableArray array];
	for (char **e = environ; *e != NULL; e++) {
		NSString *entry = [NSString stringWithUTF8String:*e];
		NSString *key = [entry componentsSeparatedByString:@"="].firstObject ?: @"";
		if ([key isEqualToString:@"LANG"] || [key hasPrefix:@"LC_"]) continue;
		[pairs addObject:entry];
	}
	[pairs addObject:@"LANG=C"];
	[pairs addObject:@"LC_ALL=C"];

	char **envp = calloc(pairs.count + 1, sizeof(char *));
	for (NSUInteger i = 0; i < pairs.count; i++) envp[i] = strdup(pairs[i].UTF8String);
	envp[pairs.count] = NULL;
	return envp;
}

static void RTFreeEnviron(char **envp) {
	if (!envp) return;
	for (char **e = envp; *e != NULL; e++) free(*e);
	free(envp);
}

NSString *const RTRepoStoreErrorDomain = @"com.qcom-toolbox.repo-transphere-tool";

static NSString *const kSourcesListDir = @"/var/jb/etc/apt/sources.list.d";
static NSString *const kImportListName = @"RepoTransphereImport.list";

// Jailbreak-installed .app bundles registered via `uicache -p` never go
// through installd's normal container-provisioning step, so
// NSTemporaryDirectory() specifically has been observed unwritable on
// device. The app's real Documents directory (below) is a different part
// of the container and, being what UIFileSharingEnabled exposes as
// "On My iPhone > Repo Transphere Tool" in the Files app, is the same
// mechanism Chrome/VLC/etc. use for their own visible per-app folder.
static NSString *RTTransferDir(void) {
	NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
	return paths.firstObject;
}

@implementation RTRepoStore

#pragma mark - Parsing existing sources

// Appended to write-failure messages so a permission problem shows its own
// cause directly in the app's alert, without needing SSH to inspect it.
static NSString *RTDiagnosticSuffix(NSString *path) {
	NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
	NSString *owner = attrs[NSFileOwnerAccountName] ?: @"?";
	NSString *group = attrs[NSFileGroupOwnerAccountName] ?: @"?";
	NSNumber *posix = attrs[NSFilePosixPermissions];
	NSString *mode = posix ? [NSString stringWithFormat:@"0%o", posix.unsignedShortValue] : @"?";
	return [NSString stringWithFormat:@"\n\n[debug] %@ — owner=%@ group=%@ mode=%@ — this app runs as uid=%d gid=%d",
		path, owner, group, mode, getuid(), getgid()];
}

// sources.list.d is root:wheel 0755 on this jailbreak (confirmed on-device
// via RTDiagnosticSuffix), so this app — which runs as plain "mobile" even
// fully unsandboxed, since no-sandbox disables Apple's MAC/Seatbelt layer
// and grants nothing at the Unix DAC/privilege level — cannot create a
// file there directly. Runs `sudo tee -a <path>` to do the actual write,
// feeding the append data (and, if given, the password) through a pipe —
// never via a shell string — so repo URLs from an imported file can never
// be interpreted as shell syntax, and the password never appears in argv
// (visible to other processes) or on disk.
//
// With password == nil, uses `sudo -n` (never prompts; fails fast if this
// jailbreak's sudo isn't configured passwordless) and sets
// *passwordRequiredOut if that's specifically why it failed, so the
// caller knows to re-prompt rather than treating it as a hard failure.
// With a password supplied, uses `sudo -S` and pipes "<password>\n" ahead
// of the actual data — sudo consumes exactly that line for the prompt and
// hands the remaining bytes on the same stream through to tee.
static BOOL RTPrivilegedAppend(NSData *data, NSString *path, NSString *_Nullable password, BOOL *passwordRequiredOut, NSString **errorOut) {
	NSString *sudoPath = nil;
	for (NSString *candidate in @[@"/var/jb/usr/bin/sudo", @"/usr/bin/sudo"]) {
		if (access(candidate.UTF8String, X_OK) == 0) { sudoPath = candidate; break; }
	}
	if (!sudoPath) {
		if (errorOut) *errorOut = @"No `sudo` binary found on this device (checked /var/jb/usr/bin/sudo and /usr/bin/sudo).";
		return NO;
	}

	NSString *teePath = nil;
	for (NSString *candidate in @[@"/var/jb/usr/bin/tee", @"/usr/bin/tee"]) {
		if (access(candidate.UTF8String, X_OK) == 0) { teePath = candidate; break; }
	}
	if (!teePath) {
		if (errorOut) *errorOut = @"No `tee` binary found (checked /var/jb/usr/bin/tee and /usr/bin/tee).";
		return NO;
	}

	int stdinPipe[2], stderrPipe[2];
	if (pipe(stdinPipe) != 0 || pipe(stderrPipe) != 0) {
		if (errorOut) *errorOut = @"Could not create pipes to talk to sudo.";
		return NO;
	}

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_init(&actions);
	posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO);
	posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO);
	posix_spawn_file_actions_addclose(&actions, stdinPipe[1]);
	posix_spawn_file_actions_addclose(&actions, stderrPipe[0]);

	NSString *sudoFlag = password ? @"-S" : @"-n";
	NSArray<NSString *> *argv = @[sudoPath, sudoFlag, teePath, @"-a", path];
	NSUInteger argc = argv.count;
	char **cArgv = calloc(argc + 1, sizeof(char *));
	for (NSUInteger i = 0; i < argc; i++) cArgv[i] = strdup(argv[i].UTF8String);

	char **cEnv = RTEnvironWithCLocale();
	pid_t pid = 0;
	int spawnStatus = posix_spawn(&pid, sudoPath.UTF8String, &actions, NULL, cArgv, cEnv);
	RTFreeEnviron(cEnv);

	posix_spawn_file_actions_destroy(&actions);
	for (NSUInteger i = 0; i < argc; i++) free(cArgv[i]);
	free(cArgv);
	close(stdinPipe[0]);
	close(stderrPipe[1]);

	if (spawnStatus != 0) {
		close(stdinPipe[1]);
		close(stderrPipe[0]);
		if (errorOut) *errorOut = [NSString stringWithFormat:@"Could not launch sudo: %s", strerror(spawnStatus)];
		return NO;
	}

	if (password) {
		NSData *passwordLine = [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
		write(stdinPipe[1], passwordLine.bytes, passwordLine.length);
	}
	if (data.length > 0) {
		write(stdinPipe[1], data.bytes, data.length);
	}
	close(stdinPipe[1]);

	NSMutableData *stderrData = [NSMutableData data];
	uint8_t buf[512];
	ssize_t n;
	while ((n = read(stderrPipe[0], buf, sizeof(buf))) > 0) {
		[stderrData appendBytes:buf length:(NSUInteger)n];
	}
	close(stderrPipe[0]);

	int status = 0;
	waitpid(pid, &status, 0);

	if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
		return YES;
	}

	NSString *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
	NSString *lowerStderr = stderrText.lowercaseString;
	// LANG=C should make this always "password", but check a few other
	// languages too in case some sudo build ignores the locale override.
	NSArray<NSString *> *passwordKeywords = @[@"password", @"mot de passe", @"contraseña", @"passwort", @"senha"];
	if (!password && passwordRequiredOut) {
		for (NSString *keyword in passwordKeywords) {
			if ([lowerStderr rangeOfString:keyword].location != NSNotFound) {
				*passwordRequiredOut = YES;
				break;
			}
		}
	}

	if (errorOut) {
		*errorOut = [NSString stringWithFormat:@"sudo tee exited %d.%@", WIFEXITED(status) ? WEXITSTATUS(status) : -1,
			stderrText.length > 0 ? [@" stderr: " stringByAppendingString:[stderrText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]] : @""];
	}
	return NO;
}

// Best-effort: hand ownership of a just-created file to mobile:mobile so
// it reads normally with any tool, and reads/appears as user-owned rather
// than root-owned. Every write still goes through RTPrivilegedAppend
// regardless of whether this succeeds, so failure here is harmless.
static void RTPrivilegedChown(NSString *path, NSString *_Nullable password) {
	NSString *sudoPath = nil;
	for (NSString *candidate in @[@"/var/jb/usr/bin/sudo", @"/usr/bin/sudo"]) {
		if (access(candidate.UTF8String, X_OK) == 0) { sudoPath = candidate; break; }
	}
	NSString *chownPath = nil;
	for (NSString *candidate in @[@"/var/jb/usr/bin/chown", @"/usr/sbin/chown"]) {
		if (access(candidate.UTF8String, X_OK) == 0) { chownPath = candidate; break; }
	}
	if (!sudoPath || !chownPath) return;

	int stdinPipe[2];
	if (password && pipe(stdinPipe) != 0) return;

	posix_spawn_file_actions_t actions;
	posix_spawn_file_actions_t *actionsPtr = NULL;
	if (password) {
		posix_spawn_file_actions_init(&actions);
		posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO);
		posix_spawn_file_actions_addclose(&actions, stdinPipe[1]);
		actionsPtr = &actions;
	}

	NSArray<NSString *> *argv = @[sudoPath, password ? @"-S" : @"-n", chownPath, @"mobile:mobile", path];
	NSUInteger argc = argv.count;
	char **cArgv = calloc(argc + 1, sizeof(char *));
	for (NSUInteger i = 0; i < argc; i++) cArgv[i] = strdup(argv[i].UTF8String);

	char **cEnv = RTEnvironWithCLocale();
	pid_t pid = 0;
	int spawnStatus = posix_spawn(&pid, sudoPath.UTF8String, actionsPtr, NULL, cArgv, cEnv);
	RTFreeEnviron(cEnv);

	if (actionsPtr) posix_spawn_file_actions_destroy(actionsPtr);
	for (NSUInteger i = 0; i < argc; i++) free(cArgv[i]);
	free(cArgv);

	if (password) {
		close(stdinPipe[0]);
		if (spawnStatus == 0) {
			NSData *passwordLine = [[password stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
			write(stdinPipe[1], passwordLine.bytes, passwordLine.length);
		}
		close(stdinPipe[1]);
	}

	if (spawnStatus == 0) {
		int status = 0;
		waitpid(pid, &status, 0);
	}
}

static NSString *RTCanonicalize(NSString *url) {
	NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
	while ([trimmed hasSuffix:@"/"]) {
		trimmed = [trimmed substringToIndex:trimmed.length - 1];
	}
	return trimmed.lowercaseString;
}

// One-line "deb [options] URL suite [components...]" format.
static void RTParseListFile(NSString *contents, NSMutableArray<NSString *> *outURLs) {
	for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
		NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (line.length == 0 || [line hasPrefix:@"#"]) continue;
		if (![line hasPrefix:@"deb "] && ![line hasPrefix:@"deb-src "]) continue;

		NSArray<NSString *> *tokens = [line componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
		NSMutableArray<NSString *> *filtered = [NSMutableArray array];
		for (NSString *t in tokens) {
			if (t.length > 0) [filtered addObject:t];
		}
		if (filtered.count < 2) continue;

		NSUInteger idx = 1;
		if ([filtered[idx] hasPrefix:@"["]) {
			while (idx < filtered.count && ![filtered[idx] hasSuffix:@"]"]) idx++;
			idx++; // skip the closing-bracket token itself
		}
		if (idx >= filtered.count) continue;

		NSString *url = filtered[idx];
		if ([url rangeOfString:@"://"].location != NSNotFound) {
			[outURLs addObject:url];
		}
	}
}

// DEB822 "Types:/URIs:/Suites:/Components:" stanza format.
static void RTParseSourcesFile(NSString *contents, NSMutableArray<NSString *> *outURLs) {
	for (NSString *rawLine in [contents componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
		NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (line.length == 0 || [line hasPrefix:@"#"]) continue;

		NSRange colonRange = [line rangeOfString:@":"];
		if (colonRange.location == NSNotFound) continue;
		NSString *key = [[line substringToIndex:colonRange.location] lowercaseString];
		if (![key isEqualToString:@"uris"] && ![key isEqualToString:@"uri"]) continue;

		NSString *value = [line substringFromIndex:colonRange.location + 1];
		for (NSString *token in [value componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceCharacterSet]]) {
			if (token.length > 0 && [token rangeOfString:@"://"].location != NSNotFound) {
				[outURLs addObject:token];
			}
		}
	}
}

+ (NSArray<NSString *> *)currentRepoURLs {
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:kSourcesListDir error:nil];

	NSMutableArray<NSString *> *raw = [NSMutableArray array];
	for (NSString *entry in entries) {
		NSString *path = [kSourcesListDir stringByAppendingPathComponent:entry];
		NSString *contents = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
		if (!contents) continue;

		if ([entry.lowercaseString hasSuffix:@".list"]) {
			RTParseListFile(contents, raw);
		} else if ([entry.lowercaseString hasSuffix:@".sources"]) {
			RTParseSourcesFile(contents, raw);
		}
	}

	NSMutableDictionary<NSString *, NSString *> *byCanonical = [NSMutableDictionary dictionary];
	for (NSString *url in raw) {
		NSString *canon = RTCanonicalize(url);
		if (!byCanonical[canon]) byCanonical[canon] = url;
	}

	NSArray<NSString *> *result = byCanonical.allValues;
	return [result sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}

#pragma mark - Export

+ (NSString *)exportText {
	NSArray<NSString *> *urls = [self currentRepoURLs];

	NSMutableString *text = [NSMutableString string];
	[text appendFormat:@"# Repo Transphere Tool export - %@\n", [NSDate date].description];
	for (NSString *url in urls) {
		[text appendString:url];
		[text appendString:@"\n"];
	}
	return text;
}

+ (nullable NSURL *)writeExportFile:(NSError **)error {
	NSString *text = [self exportText];

	NSString *dir = RTTransferDir();
	NSFileManager *fm = [NSFileManager defaultManager];
	NSError *dirError = nil;
	if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&dirError]) {
		if (error) *error = dirError;
		return nil;
	}

	NSString *path = [dir stringByAppendingPathComponent:@"sileo-repos-export.txt"];
	NSError *writeError = nil;
	BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
	if (!ok) {
		if (error) *error = writeError;
		return nil;
	}
	[fm setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:path error:nil];
	return [NSURL fileURLWithPath:path];
}

#pragma mark - Import

+ (NSArray<NSString *> *)candidateURLsFromExportedText:(NSString *)text {
	NSMutableArray<NSString *> *candidates = [NSMutableArray array];
	NSMutableSet<NSString *> *seen = [NSMutableSet set];
	for (NSString *rawLine in [text componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
		NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
		if (line.length == 0 || [line hasPrefix:@"#"]) continue;
		if ([line rangeOfString:@"://"].location == NSNotFound) continue;

		NSString *canon = RTCanonicalize(line);
		if ([seen containsObject:canon]) continue;
		[seen addObject:canon];
		[candidates addObject:line];
	}
	return candidates;
}

+ (nullable NSArray<NSString *> *)importRepoURLs:(NSArray<NSString *> *)candidateURLs sudoPassword:(nullable NSString *)password error:(NSError **)error {
	NSFileManager *fm = [NSFileManager defaultManager];

	BOOL isDir = NO;
	if (![fm fileExistsAtPath:kSourcesListDir isDirectory:&isDir] || !isDir) {
		if (error) {
			*error = [NSError errorWithDomain:RTRepoStoreErrorDomain
										  code:RTRepoStoreErrorSourcesDirMissing
									  userInfo:@{NSLocalizedDescriptionKey: @"Sileo's sources.list.d directory was not found at /var/jb/etc/apt/sources.list.d. Is Sileo installed?"}];
		}
		return nil;
	}

	NSMutableSet<NSString *> *existing = [NSMutableSet set];
	for (NSString *url in [self currentRepoURLs]) {
		[existing addObject:RTCanonicalize(url)];
	}

	NSMutableArray<NSString *> *toAdd = [NSMutableArray array];
	for (NSString *candidate in candidateURLs) {
		NSString *canon = RTCanonicalize(candidate);
		if (canon.length == 0) continue;
		if (![existing containsObject:canon]) {
			[toAdd addObject:candidate];
			[existing addObject:canon]; // guard against dupes within candidateURLs itself
		}
	}

	if (toAdd.count == 0) {
		return @[];
	}

	NSString *importPath = [kSourcesListDir stringByAppendingPathComponent:kImportListName];
	BOOL alreadyExists = [fm fileExistsAtPath:importPath];

	NSMutableString *appendText = [NSMutableString string];
	if (!alreadyExists) {
		[appendText appendString:@"# Added by Repo Transphere Tool. Safe to edit or delete by hand.\n"];
	}
	for (NSString *url in toAdd) {
		[appendText appendFormat:@"deb %@ ./\n", url];
	}

	// sources.list.d is root:wheel 0755 (confirmed on-device), so a direct
	// write from this app — which runs as plain "mobile" even unsandboxed
	// — is never permitted here; go through sudo instead.
	NSString *sudoError = nil;
	BOOL passwordRequired = NO;
	if (!RTPrivilegedAppend([appendText dataUsingEncoding:NSUTF8StringEncoding], importPath, password, &passwordRequired, &sudoError)) {
		if (error) {
			if (passwordRequired) {
				*error = [NSError errorWithDomain:RTRepoStoreErrorDomain
											  code:RTRepoStoreErrorPasswordRequired
										  userInfo:@{NSLocalizedDescriptionKey: @"This device's sudo requires a password."}];
			} else {
				NSString *message = [(sudoError ?: @"Write failed.") stringByAppendingString:RTDiagnosticSuffix(kSourcesListDir)];
				*error = [NSError errorWithDomain:RTRepoStoreErrorDomain code:RTRepoStoreErrorUnreadableFile userInfo:@{NSLocalizedDescriptionKey: message}];
			}
		}
		return nil;
	}

	if (!alreadyExists) {
		RTPrivilegedChown(importPath, password); // best-effort; future appends go through sudo regardless
	}

	return toAdd;
}

#pragma mark - Transfer folder

+ (NSString *)transferDirectoryPath {
	return RTTransferDir();
}

+ (NSArray<NSString *> *)pendingImportFileNames {
	NSString *dir = RTTransferDir();
	NSFileManager *fm = [NSFileManager defaultManager];
	NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:dir error:nil];

	NSMutableArray<NSString *> *names = [NSMutableArray array];
	for (NSString *entry in entries) {
		if ([entry.lowercaseString hasSuffix:@".txt"]) {
			[names addObject:entry];
		}
	}

	return [names sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
		NSString *pathA = [dir stringByAppendingPathComponent:a];
		NSString *pathB = [dir stringByAppendingPathComponent:b];
		NSDate *dateA = [fm attributesOfItemAtPath:pathA error:nil][NSFileModificationDate] ?: [NSDate distantPast];
		NSDate *dateB = [fm attributesOfItemAtPath:pathB error:nil][NSFileModificationDate] ?: [NSDate distantPast];
		return [dateB compare:dateA];
	}];
}

+ (nullable NSString *)contentsOfPendingImportFileNamed:(NSString *)name error:(NSError **)error {
	NSString *path = [RTTransferDir() stringByAppendingPathComponent:name];
	return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:error];
}

@end
