I'm building a Theos app for an iOS 15 rootless jailbreak (Dopamine/palera1n-style, `/var/jb` prefix). It exports Sileo's list of package sources to a file and re-imports them on another device. The tool's own logic is done and works. The blocker is purely install/registration: after a clean `apt install` that reports success, the app never appears anywhere on the phone — not the home screen, not Files' "On My iPhone" list, nothing. I need help diagnosing why.

**Confirmed working:**
- `dpkg`/`apt install` succeeds with no error.
- `THEOS_PACKAGE_SCHEME = rootless` and `FINALPACKAGE = 1` are hardcoded in the Makefile (not left to a shell export).
- Built a completely minimal, zero-entitlement Theos app (`~/MinimalTest`) as a baseline test — it *also* never showed up. So this isn't about my app's specific Info.plist/entitlements config.
- Built an alternative as a Settings panel via PreferenceLoader (`~/RepoTransphereSettings`, a `.bundle` + PreferenceLoader entry plist instead of a standalone `.app`) — **this one does show up** in Settings after a respring. That proves `dpkg`, the staging/packaging, and the rootless install path are all fine in general.
- However, the Settings-panel version can't actually do its job: it runs inside Settings.app's own (stock, sandboxed) process, so it hits permission errors touching the filesystem. That path is a dead end for functionality — entitlements apply to a process's own code signature, not to a bundle loaded into someone else's process. I'm not pursuing that further; it was only useful as a diagnostic.

**Not yet confirmed:** whether `uicache` itself runs cleanly on this device. I asked for `which uicache` and `uicache; echo $?` output over SSH multiple times but never got it before the conversation ended. This is the next concrete thing to check — since a working PreferenceLoader-based install proves dpkg/staging isn't the problem, the remaining suspects are all in the standalone-app registration path specifically: `uicache`, `installd`/MobileInstallation's validation of `.app` bundles, or possibly needing a full reboot rather than just uicache+respring for a *new* bundle ID's first registration.

**Project locations:**
- `~/RepoTransphereTool` — the real app (Makefile, control, Resources/Info.plist, Resources/Entitlements.plist, Application/*.m). Entitlements currently: only `com.apple.private.security.no-sandbox` and `com.apple.private.skip-library-validation` (I removed `platform-application` earlier since that entitlement can make MobileInstallation refuse to register a `.deb`-installed bundle as a normal app at all — untested whether that alone fixed it, since I pivoted to the Settings-panel experiment before rebuilding/testing that specific change).
- `~/MinimalTest` — the zero-entitlement baseline, also broken.
- `~/RepoTransphereSettings` — the Settings-panel variant, works for visibility, sandboxed for file access.
- Theos is at `~/theos`.

**What I need:** help getting `~/RepoTransphereTool` to actually register as an installed app (show up on the home screen and in Files) after install, on this specific device/jailbreak. Please start by asking me to run `which uicache` and `uicache` over SSH and share the exact output before proposing anything else — that's the one piece of evidence needed to know whether uicache itself is broken, versus something deeper in app registration on this jailbreak.
