#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const RTRepoStoreErrorDomain;

typedef NS_ENUM(NSInteger, RTRepoStoreError) {
	RTRepoStoreErrorSourcesDirMissing = 1,
	RTRepoStoreErrorEmptyFile = 2,
	RTRepoStoreErrorUnreadableFile = 3,
	// sudo -n failed specifically because it needs a password; retry via
	// importRepoURLs:sudoPassword:error: with one supplied.
	RTRepoStoreErrorPasswordRequired = 4,
};

@interface RTRepoStore : NSObject

// All repo URLs currently configured in Sileo (from every .list / .sources
// file under /var/jb/etc/apt/sources.list.d), deduplicated and sorted.
+ (NSArray<NSString *> *)currentRepoURLs;

// Every currently configured repo URL, one per line, as plain text ready
// to hand off (served over the network or written to a file).
+ (NSString *)exportText;

// Writes exportText to a fresh file in the app's own Documents folder (see
// transferDirectoryPath). Returns the file URL, or nil (with *error set)
// on failure. Kept as a fallback for setups where the app's Data container
// actually works; not relied on as the primary transfer mechanism.
+ (nullable NSURL *)writeExportFile:(NSError **)error;

// Parses candidateURLs (as read from an imported export file) and adds
// whichever ones aren't already configured to a dedicated Sileo source
// list, without touching or duplicating any existing entry. Returns the
// URLs that were actually added (may be empty if everything already
// existed), or nil (with *error set) on failure.
//
// sources.list.d is root-owned, so the actual write goes through `sudo`.
// Pass sudoPassword as nil to try passwordless (`sudo -n`) first; if that
// specifically fails because a password is required, *error will have
// code RTRepoStoreErrorPasswordRequired — call again with the password
// the user entered. The password is only ever held in memory for this one
// call (piped directly to sudo's stdin) and is never written to disk.
+ (nullable NSArray<NSString *> *)importRepoURLs:(NSArray<NSString *> *)candidateURLs sudoPassword:(nullable NSString *)password error:(NSError **)error;

// Splits raw exported-file text into candidate repo URL strings, ignoring
// blank lines and comment lines.
+ (NSArray<NSString *> *)candidateURLsFromExportedText:(NSString *)text;

// The app's own Documents folder: what writeExportFile: writes into, what
// pendingImportFileNames scans, and (via UIFileSharingEnabled in
// Info.plist) the same folder that shows up as "On My iPhone > Repo
// Transphere Tool" in the Files app, the same mechanism Chrome/VLC/etc.
// use for their own visible per-app folder.
+ (NSString *)transferDirectoryPath;

// Names of .txt files sitting in transferDirectoryPath, newest first.
+ (NSArray<NSString *> *)pendingImportFileNames;

// Reads one of the files returned by pendingImportFileNames, by name.
+ (nullable NSString *)contentsOfPendingImportFileNamed:(NSString *)name error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
